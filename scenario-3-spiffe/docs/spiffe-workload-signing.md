# SPIFFE workload identity for automatic cosign signing

Scenario 3 replaces Kubernetes TokenRequest scripts with **SPIFFE JWT-SVIDs** issued by SPIRE after workload attestation.

## Setup

End-to-end SPIRE install + Fulcio federation + pipeline apply is in
**[README.md — Setup SPIFFE](../README.md#setup-spiffe-required-before-cosign)**
(`openshift/spire/*.yaml` templates + `envsubst`).

This document focuses on *why* SPIFFE for signing and the Cosign / Fulcio identity details.

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
    # Cosign expects a filesystem path (it prepends unix://). OpenShift ZTWIM
    # exposes spire-agent.sock (not agent.sock).
    value: /spiffe-workload-api/spire-agent.sock
```

Cosign’s SPIFFE provider reads `SPIFFE_ENDPOINT_SOCKET`, fetches a JWT-SVID with audience `sigstore`, and uses it as the Fulcio identity token. Pass `--oidc-provider=spiffe` so Cosign does not fall back to interactive device flow. Do **not** set `--fulcio-auth-flow=token` unless you also pass `--identity-token` (token flow with an empty token yields `compact JWS format must have three parts`).

## Step 4 — Automatic signing (no token script)

Inside the `spiffe-sign` task:

```bash
TUF_ROOT_CHECKSUM=$(curl -sS "${TUF_URL}/1.root.json" | sha256sum | awk '{print $1}')
cosign initialize \
  --mirror "$TUF_URL" \
  --root "$TUF_URL/1.root.json" \
  --root-checksum "$TUF_ROOT_CHECKSUM"

# Cosign 3: put Fulcio / Rekor / SPIRE OIDC in a signing config (not deprecated CLI flags).
cosign signing-config create \
  --no-default-fulcio --no-default-rekor --no-default-oidc --no-default-tsa \
  --fulcio="url=${FULCIO_URL},api-version=1,start-time=2020-01-01T00:00:00Z,operator=redhat.com" \
  --rekor="url=${REKOR_URL},api-version=1,start-time=2020-01-01T00:00:00Z,operator=redhat.com" \
  --rekor-config=ANY \
  --oidc-provider="url=https://oidc-discovery.<spire-domain>,api-version=1,start-time=2020-01-01T00:00:00Z,operator=spire" \
  --out signing-config.json

# Cosign detects SPIFFE via SPIFFE_ENDPOINT_SOCKET (filesystem path, not unix:// URI)
cosign sign -y \
  --signing-config=signing-config.json \
  --oidc-provider=spiffe \
  "${IMAGE}"
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

Add to `Securesign.spec.fulcio.config.OIDCIssuers` (via `openshift/fulcio-spire-oidc-patch.json`):

```yaml
- Issuer: "https://oidc-discovery.<apps-domain>"
  IssuerURL: "https://oidc-discovery.<apps-domain>"
  ClientID: "sigstore"
  Type: spiffe
  SPIFFETrustDomain: "<TRUST_DOMAIN>"   # e.g. apps.cluster-xxx.example.com
```

`Type: spiffe` is required for JWT-SVID subjects (`spiffe://…`). `Type: uri` expects
`https://…` subjects and Fulcio returns 400 `There was an error processing the identity token`.

`SPIFFETrustDomain` must match the trust domain embedded in the SPIFFE ID (same value as
`ZeroTrustWorkloadIdentityManager.spec.trustDomain` / ClusterSPIFFEID template).

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
| Cosign uses device flow / `OIDC provider ''` / PKCE error | Set `SPIFFE_ENDPOINT_SOCKET` to `/spiffe-workload-api/spire-agent.sock` (path only, correct filename) |
| Cosign `compact JWS … three parts` | Wrong/missing socket → empty identity token; do not use `--fulcio-auth-flow=token` without `--identity-token` |
| cosign can't find SPIFFE socket | CSI driver installed; pod has `rhtas.demo/signer=true` label; inspect `probe-spiffe-socket` logs |
| Fulcio rejects JWT / 400 processing identity token | Use `Type: spiffe` + `SPIFFETrustDomain`; `ClientID: sigstore`; issuer URL = `$JWT_ISSUER` |
| Wrong SPIFFE ID | ClusterSPIFFEID selector vs pod labels |
| `audience` mismatch | SPIRE entry must allow `sigstore` audience |

## When to use Scenario 3 vs 1/2

- **S1** — You own a Jenkins estate and want explicit control of the sign step
- **S2** — You want platform-managed signing on OpenShift Pipelines without pipeline changes
- **S3** — You need attested workload identity, federation, or secretless signing at scale
