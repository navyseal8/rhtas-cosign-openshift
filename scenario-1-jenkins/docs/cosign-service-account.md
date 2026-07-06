# Cosign signing with a Jenkins robot ServiceAccount

This is the **fully explained** token flow for Scenario 1. No long-lived cosign keys are stored in Jenkins.

## Concepts

| Term | Meaning |
|------|---------|
| **Robot ServiceAccount** | Kubernetes `ServiceAccount` used only by CI (`rhtas-signer`), not a human user |
| **serviceAccountIssuer** | Cluster OIDC issuer URL — Fulcio trusts tokens from this issuer |
| **TokenRequest** | Kubernetes API to mint a short-lived JWT with a specific **audience** |
| **Keyless signing** | cosign sends the JWT to Fulcio; Fulcio returns a short-lived X.509 cert bound to the SA identity |

## Identity format

After signing, the Fulcio certificate identity is:

```
https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer
```

Verification uses this exact string (or a regex) plus the cluster OIDC issuer.

## Step-by-step setup

### Step 1 — Confirm cluster issuer

```bash
export CLUSTER_OIDC_ISSUER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')
echo "$CLUSTER_OIDC_ISSUER"
```

If empty, your cluster admin must configure `Authentication.spec.serviceAccountIssuer` (standard on ROSA/OCP 4.14+).

### Step 2 — Configure RHTAS Fulcio

Edit the `Securesign` CR and add the kubernetes issuer (see [rhtas-setup.md](../../docs/rhtas-setup.md)):

```yaml
OIDCIssuers:
  - Issuer: "<CLUSTER_OIDC_ISSUER>"
    IssuerURL: "<CLUSTER_OIDC_ISSUER>"
    ClientID: "trusted-artifact-signer"
    Type: kubernetes
```

Wait for Fulcio to reconcile (`oc get fulcio -n trusted-artifact-signer`).

### Step 3 — Create the robot ServiceAccount

```bash
oc apply -f ../openshift/serviceaccount-signer.yaml
```

```yaml
# serviceaccount-signer.yaml (summary)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhtas-signer
  namespace: rhtas-demo-ci
```

This SA is the **signing identity**. Treat it like a robot account: narrow RBAC, no human login.

### Step 4 — Grant TokenRequest permission

The Jenkins agent must create tokens **for** `rhtas-signer`. Apply:

```bash
oc apply -f ../openshift/rolebinding-tokenrequest.yaml
```

This allows the Jenkins agent SA (or the same `rhtas-signer` SA) to call `serviceaccounts/token` on `rhtas-signer`.

### Step 5 — Configure Jenkins pod to use the ServiceAccount

In your Jenkins Kubernetes cloud Pod template:

1. **Service Account:** `rhtas-signer`
2. **Namespace:** `rhtas-demo-ci`
3. Ensure the pod runs on OpenShift (not a plain K8s cluster without OIDC tokens)

When the pod starts, OpenShift projects a service account token. For signing we prefer an explicit **TokenRequest** with audience `sigstore` (Fulcio requirement).

### Step 6 — Request a signing token in the pipeline

The helper script `scripts/request-signing-token.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SA_NAMESPACE="${SA_NAMESPACE:-rhtas-demo-ci}"
SA_NAME="${SA_NAME:-rhtas-signer}"
AUDIENCE="${AUDIENCE:-sigstore}"
DURATION="${DURATION:-3600}"

# Uses in-cluster credentials (Jenkins agent pod)
TOKEN=$(oc create token "$SA_NAME" \
  --namespace "$SA_NAMESPACE" \
  --audience "$AUDIENCE" \
  --duration "${DURATION}s")

echo "$TOKEN"
```

**Alternative without `oc`** — raw TokenRequest API:

```bash
TOKEN=$(curl -sS -X POST \
  -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  -H "Content-Type: application/json" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  "https://kubernetes.default.svc/api/v1/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer/token" \
  -d '{"spec":{"audiences":["sigstore"],"expirationSeconds":3600}}' \
  | jq -r '.status.token')
```

### Step 7 — Initialize cosign for RHTAS

```bash
export TUF_URL=$(oc get tuf -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
export COSIGN_FULCIO_URL=$(oc get fulcio -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
export COSIGN_REKOR_URL=$(oc get rekor -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
export COSIGN_OIDC_ISSUER="$CLUSTER_OIDC_ISSUER"
export COSIGN_CERTIFICATE_OIDC_ISSUER="$CLUSTER_OIDC_ISSUER"
export COSIGN_MIRROR="$TUF_URL"
export COSIGN_ROOT="$TUF_URL/root.json"
export COSIGN_YES=true

cosign initialize --mirror "$COSIGN_MIRROR" --root "$COSIGN_ROOT"
```

### Step 8 — Sign the image

```bash
export IDENTITY_TOKEN=$(./scripts/request-signing-token.sh)

cosign login quay.io -u "$QUAY_USER" -p "$QUAY_PASSWORD"

cosign sign -y \
  --identity-token "$IDENTITY_TOKEN" \
  "quay.io/${QUAY_ORG}/rhtas-hello-world:jenkins-${BUILD_NUMBER}"
```

**What happens internally:**

1. cosign sends the JWT to **Fulcio** with audience `sigstore`
2. Fulcio validates issuer = cluster `serviceAccountIssuer`
3. Fulcio issues an X.509 cert with subject = SA identity URL
4. cosign signs the image digest and uploads signature to Quay
5. cosign uploads an entry to **Rekor** (transparency log)

### Step 9 — Verify before GitOps promotion

```bash
cosign verify \
  --certificate-identity="https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer" \
  --certificate-oidc-issuer="$COSIGN_CERTIFICATE_OIDC_ISSUER" \
  "quay.io/${QUAY_ORG}/rhtas-hello-world:jenkins-${BUILD_NUMBER}"
```

Only after verify succeeds should the pipeline update the GitOps image tag.

## Passing the token — security notes

| Do | Don't |
|----|-------|
| Request a fresh token per build | Store tokens in Jenkins credentials |
| Use audience `sigstore` | Reuse default SA tokens with wrong audience |
| Keep token in env var for one stage | Echo token to console (`set +x` in pipeline) |
| Scope SA to `rhtas-demo-ci` only | Use `cluster-admin` SA for signing |
| Rotate Quay robot password separately | Put Quay password in git |

## Troubleshooting

| Error | Fix |
|-------|-----|
| `invalid audience` | TokenRequest must include `"sigstore"` audience |
| `oidc issuer not found` | Add kubernetes issuer to Securesign Fulcio config |
| `permission denied` on token | Apply `rolebinding-tokenrequest.yaml` |
| `UNAUTHORIZED` on push | Check Quay robot secret and `cosign login` |
| Verify identity mismatch | Certificate identity must match SA namespace/name exactly |

## Comparison with Scenario 2 and 3

| | Scenario 1 | Scenario 2 | Scenario 3 |
|---|------------|------------|------------|
| Who calls cosign | Jenkins pipeline script | Tekton Chains controller | Signer workload / ambient SPIFFE |
| Token source | TokenRequest on `rhtas-signer` | TaskRun ServiceAccount | SPIFFE JWT-SVID |
| In pipeline YAML | Explicit `cosign sign` step | No cosign step | No manual token script |
