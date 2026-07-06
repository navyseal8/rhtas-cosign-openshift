# Prerequisites

## Cluster

| Component | Minimum version | Notes |
|-----------|-----------------|-------|
| OpenShift Container Platform | 4.17+ | RHTAS 1.4 Operator compatibility |
| OpenShift Pipelines | 1.14+ | Scenario 2 — Tekton Chains |
| OpenShift GitOps | 1.12+ | Last-mile deploy (or standalone Argo CD) |
| Jenkins (OpenShift) | 4.x | Scenario 1 — optional if Jenkins already exists |
| Zero Trust Workload Identity Manager | GA (OCP 4.20+) | Scenario 3 — SPIFFE/SPIRE |

## Operators to install

```bash
# RHTAS
oc apply -f https://...  # or install via OperatorHub → Red Hat Trusted Artifact Signer

# OpenShift Pipelines (includes Tekton Chains controller)
oc apply -f openshift-pipelines-operator.yaml

# OpenShift GitOps
oc apply -f openshift-gitops-operator.yaml

# Scenario 3 only
# OperatorHub → Zero Trust Workload Identity Manager
```

## Workstation tools

```bash
oc version
cosign version    # 3.0+ recommended for RHTAS 1.4+
skopeo --version
jq --version
```

## Registry

- Quay organization with robot account for CI push
- Robot credentials stored as OpenShift Secrets (never commit plaintext)
- Registry must allow cosign signature blobs (same repo as image)

## RHTAS OIDC for cluster ServiceAccounts

Scenarios 1 and 3 use **keyless signing** with the cluster's `serviceAccountIssuer`. Confirm it is set:

```bash
oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
```

RHTAS `Securesign` must include an OIDC issuer entry with `Type: kubernetes` pointing at that URL. See [rhtas-setup.md](rhtas-setup.md).

## Namespaces (created by setup scripts or manually)

| Namespace | Purpose |
|-----------|---------|
| `trusted-artifact-signer` | RHTAS components (operator default) |
| `rhtas-demo-ci` | Jenkins / Tekton build workloads |
| `rhtas-demo-dev` | GitOps-deployed hello-world app |
| `openshift-gitops` | Argo CD instance |

## Credentials checklist

- [ ] Quay robot account (`QUAY_USER`, `QUAY_PASSWORD` or token)
- [ ] Git credentials for GitOps repo write (pipeline updates image tag)
- [ ] Cluster admin for RHTAS and Chains configuration
- [ ] Jenkins credentials (Scenario 1) bound to `rhtas-signer` SA token flow
