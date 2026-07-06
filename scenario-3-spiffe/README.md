# Scenario 3 — SPIFFE workload identity with automatic cosign signing

Demonstrates **Zero Trust Workload Identity Manager** (SPIFFE/SPIRE) issuing short-lived JWT-SVIDs to a signer workload. Cosign uses the SPIFFE identity automatically — no manual TokenRequest script, no static keys.

## What this proves

- Workload attestation before identity issuance (SPIRE)
- SPIFFE ID as Fulcio certificate identity
- Federation between SPIRE OIDC discovery and RHTAS Fulcio
- Signing happens inside an attested pod without human or Jenkins credentials

## Architecture

```
ClusterSPIFFEID (selector: tekton signer pod labels)
        ↓
SPIRE Server → SPIRE Agent → JWT-SVID mounted via CSI / socket
        ↓
signer sidecar OR cosign with SPIFFE provider
        ↓
Fulcio (trusts SPIRE OIDC issuer) → Rekor → Quay signature
```

## Prerequisites

- [Zero Trust Workload Identity Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/security_and_compliance/zero-trust-workload-identity-manager) installed
- SPIRE `SpiffeID` trust domain configured (e.g. `spiffe://prod.example.com`)
- RHTAS Fulcio configured with **additional** OIDC issuer for SPIRE OIDC discovery endpoint

## Setup

### 1. Install Workload Identity Manager

```bash
# OperatorHub → Zero Trust Workload Identity Manager
# Create SpiffeID / SPIRE instance per product docs
oc get spiffeid,spire -A
```

### 2. Register signer workload identity

```bash
oc apply -f openshift/clusterspiffeid-tekton-signer.yaml
```

This maps pods with label `rhtas.demo/signer: "true"` to:

```
spiffe://<trust-domain>/ns/rhtas-demo-ci/sa/spiffe-cosign-signer
```

### 3. Federate SPIRE OIDC with RHTAS Fulcio

Add SPIRE's OIDC discovery URL to `Securesign` Fulcio `OIDCIssuers`:

```yaml
- Issuer: "https://oidc-discovery.<spire-domain>"
  IssuerURL: "https://oidc-discovery.<spire-domain>"
  ClientID: "trusted-artifact-signer"
  Type: email   # or per SPIRE JWT-SVID claims documentation
```

See [docs/spiffe-workload-signing.md](docs/spiffe-workload-signing.md).

### 4. Deploy SPIFFE-enabled pipeline

```bash
# Reuse build tasks from Scenario 2
oc apply -f ../scenario-2-tekton/openshift/tasks.yaml

oc apply -f openshift/namespace.yaml
oc apply -f openshift/spiffe-signer-sa.yaml
oc apply -f openshift/tasks-spiffe.yaml
oc apply -f openshift/pipeline-spiffe.yaml
```

### 5. Run

```bash
tkn pipeline start rhtas-hello-world-spiffe \
  -n rhtas-demo-ci \
  --param quay-org=acme \
  --workspace name=shared-workspace,volumeClaimTemplateFile=../scenario-2-tekton/openshift/workspace-pvc.yaml \
  --showlog
```

The `spiffe-sign` task runs **after** image push. Cosign obtains a JWT-SVID from the SPIFFE workload API (`SPIFFE_ENDPOINT_SOCKET`) and signs without a manually passed token.

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^spiffe://.*/ns/rhtas-demo-ci/sa/spiffe-cosign-signer$' \
  --certificate-oidc-issuer="https://oidc-discovery.<spire-domain>" \
  quay.io/acme/rhtas-hello-world:spiffe-<run-id>
```

## Comparison across scenarios

| | S1 Jenkins | S2 Chains | S3 SPIFFE |
|---|------------|-----------|-----------|
| Identity | K8s SA `rhtas-signer` | K8s SA `tekton-chains-builder` | SPIFFE ID |
| Token minting | `oc create token` in pipeline | Chains controller | SPIRE agent (auto) |
| Attestation | RBAC only | TaskRun metadata | SPIRE node/workload attestation |
| cosign invocation | Explicit in Jenkinsfile | Chains controller | Signer task / ambient |

## Files

| File | Description |
|------|-------------|
| `openshift/clusterspiffeid-tekton-signer.yaml` | SPIFFE registration for signer pods |
| `openshift/pipeline-spiffe.yaml` | Build + push + SPIFFE-aware sign |
| `docs/spiffe-workload-signing.md` | OIDC federation and automatic signing flow |
