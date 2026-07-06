# RHTAS baseline setup on OpenShift

This document captures the shared RHTAS configuration used by all three scenarios.

## 1. Install the RHTAS Operator

1. Open **OperatorHub** → install **Red Hat Trusted Artifact Signer**
2. Create a `Securesign` CR in `trusted-artifact-signer` (or use the operator defaults)
3. Wait until Fulcio, Rekor, and TUF report `Ready`:

```bash
oc get fulcio,rekor,tuf -n trusted-artifact-signer
```

## 2. Record service endpoints

```bash
export RHTAS_NS=trusted-artifact-signer
export TUF_URL=$(oc get tuf -n $RHTAS_NS -o jsonpath='{.items[0].status.url}')
export COSIGN_FULCIO_URL=$(oc get fulcio -n $RHTAS_NS -o jsonpath='{.items[0].status.url}')
export COSIGN_REKOR_URL=$(oc get rekor -n $RHTAS_NS -o jsonpath='{.items[0].status.url}')
export CLUSTER_OIDC_ISSUER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')

echo "TUF_URL=$TUF_URL"
echo "FULCIO=$COSIGN_FULCIO_URL"
echo "REKOR=$COSIGN_REKOR_URL"
echo "CLUSTER_OIDC_ISSUER=$CLUSTER_OIDC_ISSUER"
```

## 3. Trust the cluster ServiceAccount issuer (required)

For robot-account / workload signing, add the cluster issuer to Fulcio:

```bash
oc edit securesign -n trusted-artifact-signer
```

Under `spec.fulcio.config.OIDCIssuers`, add:

```yaml
- Issuer: "<CLUSTER_OIDC_ISSUER>"
  IssuerURL: "<CLUSTER_OIDC_ISSUER>"
  ClientID: "trusted-artifact-signer"
  Type: kubernetes
```

Replace `<CLUSTER_OIDC_ISSUER>` with the value from step 2.

> **Why:** Fulcio issues short-lived signing certificates bound to the OIDC identity in the token. For OpenShift ServiceAccounts, the identity is:
>
> `https://kubernetes.io/namespaces/<ns>/serviceaccounts/<sa-name>`

## 4. Initialize cosign against RHTAS TUF root

On your workstation or in CI agents:

```bash
export COSIGN_MIRROR=$TUF_URL
export COSIGN_ROOT=$TUF_URL/root.json
export COSIGN_FULCIO_URL
export COSIGN_REKOR_URL
export COSIGN_OIDC_ISSUER=$CLUSTER_OIDC_ISSUER
export COSIGN_CERTIFICATE_OIDC_ISSUER=$CLUSTER_OIDC_ISSUER
export COSIGN_YES=true

cosign initialize --mirror "$COSIGN_MIRROR" --root "$COSIGN_ROOT"
```

## 5. Optional — admission policy

To enforce signed images at deploy time, configure OpenShift admission or a policy engine (Kyverno, Sigstore Policy Controller) with:

- **OIDC issuer:** cluster `serviceAccountIssuer` or SPIFFE OIDC discovery URL (Scenario 3)
- **Certificate identity:** regex matching your signer ServiceAccounts or SPIFFE IDs

Example verify command:

```bash
cosign verify \
  --certificate-identity="https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer" \
  --certificate-oidc-issuer="$COSIGN_CERTIFICATE_OIDC_ISSUER" \
  quay.io/<org>/rhtas-hello-world:jenkins-42
```

## 6. Quay robot account

1. Create robot `rhtas-ci` in Quay with **Write** on `rhtas-hello-world` repo
2. Create pull secret in `rhtas-demo-ci`:

```bash
oc create secret docker-registry quay-credentials \
  --docker-server=quay.io \
  --docker-username=<robot> \
  --docker-password=<token> \
  -n rhtas-demo-ci
```

## Next steps

- Scenario 1: [cosign ServiceAccount guide](../scenario-1-jenkins/docs/cosign-service-account.md)
- Scenario 2: [Tekton Chains + RHTAS](../scenario-2-tekton/docs/tekton-chains-rhtas.md)
- Scenario 3: [SPIFFE workload signing](../scenario-3-spiffe/docs/spiffe-workload-signing.md)
