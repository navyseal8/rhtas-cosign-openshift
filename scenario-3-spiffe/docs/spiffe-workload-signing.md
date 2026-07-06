# SPIFFE workload identity for automatic cosign signing

Scenario 3 replaces Kubernetes TokenRequest scripts with **SPIFFE JWT-SVIDs** issued by SPIRE after workload attestation.

## Why SPIFFE for signing?

| K8s SA token (S1/S2) | SPIFFE JWT-SVID (S3) |
|----------------------|----------------------|
| Identity tied to Kubernetes API | Cryptographic identity portable across clusters |
| RBAC controls who can mint tokens | SPIRE attestation policies (labels, selectors, node attestation) |
| Manual audience configuration | SPIRE sets `aud` claims per registration entry |
| Same cluster only | Federation across hybrid/multi-cloud |

For platform teams, SPIFFE is the **runtime identity plane**; RHTAS/cosign is the **artifact trust plane**. This scenario connects both.

## Components

```
┌─────────────────────────────────────────────────────────┐
│  Zero Trust Workload Identity Manager (OpenShift)       │
│  ├─ spire-server                                        │
│  ├─ spire-agent (DaemonSet)                             │
│  ├─ spiffe-csi-driver (mounts SVIDs into pods)          │
│  └─ oidc-discovery-provider (JWT → OIDC for Fulcio)    │
└─────────────────────────────────────────────────────────┘
         │ JWT-SVID
         ▼
┌─────────────────┐     ┌──────────────┐     ┌───────┐
│ cosign sign     │────▶│ RHTAS Fulcio │────▶│ Rekor │
│ (SPIFFE token)  │     └──────────────┘     └───────┘
└─────────────────┘
```

## Step 1 — SPIRE trust domain

After installing the operator, note your trust domain (example: `prod.openshift.example.com`).

SPIFFE IDs follow:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>
```

For this demo:

```
spiffe://prod.openshift.example.com/ns/rhtas-demo-ci/sa/spiffe-cosign-signer
```

## Step 2 — ClusterSPIFFEID

`openshift/clusterspiffeid-tekton-signer.yaml` tells the SPIRE controller manager to auto-register pods matching:

```yaml
podSelector:
  matchLabels:
    rhtas.demo/signer: "true"
```

SPIRE issues X.509-SVID and JWT-SVID to matching workloads.

## Step 3 — Mount SPIFFE socket in signer pod

The Tekton task template includes:

```yaml
volumes:
  - name: spiffe-workload-api
    csi:
      driver: "csi.spiffe.io"
      readOnly: true
volumeMounts:
  - name: spiffe-workload-api
    mountPath: /spiffe-workload-api
    readOnly: true
env:
  - name: SPIFFE_ENDPOINT_SOCKET
    value: unix:///spiffe-workload-api/agent.sock
```

Cosign 2.x+ includes a **SPIFFE workload identity provider** that reads `SPIFFE_ENDPOINT_SOCKET` and fetches a JWT-SVID with audience `sigstore`.

## Step 4 — Automatic signing (no token script)

Inside the `spiffe-sign` task:

```bash
export COSIGN_FULCIO_URL=...
export COSIGN_REKOR_URL=...
export COSIGN_OIDC_ISSUER=https://oidc-discovery.<spire-domain>
export COSIGN_CERTIFICATE_OIDC_ISSUER=https://oidc-discovery.<spire-domain>

cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json"

# Cosign detects SPIFFE via SPIFFE_ENDPOINT_SOCKET — no --identity-token flag
cosign sign -y "${IMAGE}"
```

**Automatic** means:

- No `oc create token`
- No Jenkins credential for signing
- JWT-SVID rotated by SPIRE (short TTL)
- Identity bound to attested workload labels

## Step 5 — Configure RHTAS Fulcio to trust SPIRE OIDC

SPIRE's OIDC discovery provider exposes:

```
https://oidc-discovery.<domain>/.well-known/openid-configuration
```

Add to `Securesign.spec.fulcio.config.OIDCIssuers`:

```yaml
- Issuer: "https://oidc-discovery.spire.example.com"
  IssuerURL: "https://oidc-discovery.spire.example.com"
  ClientID: "trusted-artifact-signer"
  Type: email
```

Fulcio validates JWT-SVID `sub` claim matches the SPIFFE ID registered for the workload.

## Step 6 — Verify with SPIFFE identity

```bash
cosign verify \
  --certificate-identity="spiffe://prod.openshift.example.com/ns/rhtas-demo-ci/sa/spiffe-cosign-signer" \
  --certificate-oidc-issuer="https://oidc-discovery.spire.example.com" \
  quay.io/acme/rhtas-hello-world:spiffe-abc12
```

## Admission policy (optional)

Cluster policy can require SPIFFE-signed images from a specific trust domain:

```yaml
# Kyverno / Sigstore Policy Controller example (conceptual)
certificateIdentity: "^spiffe://prod\\.openshift\\.example\\.com/.*$"
certificateOidcIssuer: "^https://oidc-discovery\\.spire\\.example\\.com$"
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| cosign can't find SPIFFE socket | CSI driver installed; pod has `rhtas.demo/signer=true` label |
| Fulcio rejects JWT | OIDC issuer in Securesign matches SPIRE discovery URL |
| Wrong SPIFFE ID | ClusterSPIFFEID selector vs pod labels |
| `audience` mismatch | SPIRE entry must allow `sigstore` audience |

## When to use Scenario 3 vs 1/2

- **S1** — You own a Jenkins estate and want explicit control of the sign step
- **S2** — You want platform-managed signing on OpenShift Pipelines without pipeline changes
- **S3** — You need attested workload identity, federation, or secretless signing at scale
