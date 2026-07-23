# Scenario 2 — Tekton pipeline with Tekton Chains (automatic signing)

Same build and SAST steps as Jenkins, but **no cosign step in the Pipeline**. [Tekton Chains](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/securing_openshift_pipelines/using-tekton-chains-to-sign-and-verify-image-and-provenance_using-tekton-chains-for-openshift-pipelines-supply-chain-security) observes completed TaskRuns and signs the pushed OCI image automatically.

## What this proves

- Supply-chain signing decoupled from pipeline authoring
- Chains configured to use **RHTAS Fulcio/Rekor** (keyless) instead of static `signing-secrets`
- Provenance (`in-toto`) stored alongside image signatures in Quay
- Same GitOps last mile as Scenario 1

## Flow

```
PipelineRun → maven build → SAST → buildah push (no cosign in YAML)
                    ↓
         Tekton Chains (async, ~60s)
                    ↓
    cosign sign + Rekor entry (identity = TaskRun ServiceAccount)
                    ↓
         chains.tekton.dev/signed=true on TaskRun
```

## Setup

### 1. Apply namespace and pipeline

```bash
oc apply -f openshift/namespace.yaml
oc apply -f openshift/pipeline-sa.yaml
oc apply -f openshift/scc-pipelines-builder.yaml
oc apply -f openshift/tasks.yaml
oc apply -f openshift/pipeline.yaml
```

Grant the builder SA `pipelines-scc` (cluster-admin) so buildah can use uid `1000` + `SETFCAP`:

```bash
oc adm policy add-scc-to-user pipelines-scc \
  -z tekton-chains-builder -n rhtas-demo-ci

# Ensure pipelines-scc allows Buildah (required on some OCP versions)
oc patch scc pipelines-scc --type merge -p \
  '{"allowedCapabilities":["SETFCAP"],"allowPrivilegeEscalation":true}'
```

### 2. Configure Chains for RHTAS keyless signing

```bash
oc apply -f openshift/chains-rhtas-patch.yaml
```

This patches `TektonConfig` / `chains-config` to:

- Store OCI signatures in the registry (`artifacts.oci.storage: oci`)
- Enable transparency (`transparency.enabled: true`)
- Point Fulcio/Rekor/TUF at RHTAS endpoints
- Use **OIDC keyless signer** (ServiceAccount of the build TaskRun)

See [docs/tekton-chains-rhtas.md](docs/tekton-chains-rhtas.md) for full explanation.

### 3. Run the pipeline

```bash
tkn pipeline start rhtas-hello-world \
  -n rhtas-demo-ci \
  --param quay-org=rhn_support_jeretan \
  --param quay-repo=hello-world-cosign \
  --param git-url=https://github.com/navyseal8/rhtas-cosign-openshift.git \
  --param git-revision=main \
  --workspace name=shared-workspace,volumeClaimTemplateFile=openshift/workspace-pvc.yaml \
  --workspace name=docker-credentials,secret=quay-credentials \
  --workspace name=git-credentials,secret=github-credentials \
  --showlog
```

For a **private** GitHub repo, create a secret with a PAT and bind it:

```bash
oc create secret generic github-credentials \
  --from-literal=username=<github-user> \
  --from-literal=password=<github-pat> \
  -n rhtas-demo-ci

tkn pipeline start rhtas-hello-world \
  -n rhtas-demo-ci \
  --param quay-org=acme \
  --param git-url=https://github.com/navyseal8/rhtas-cosign-openshift.git \
  --workspace name=shared-workspace,volumeClaimTemplateFile=openshift/workspace-pvc.yaml \
  --workspace name=docker-credentials,secret=quay-credentials \
  --workspace name=git-credentials,secret=github-credentials \
  --showlog
```

### 4. Wait for Chains signature

```bash
TASKRUN=$(tkn pipelinerun describe <run-name> -n rhtas-demo-ci -o jsonpath='{.status.childReferences[?(@.kind=="TaskRun")].name}' | head -1)

# Poll until signed
oc get taskrun "$TASKRUN" -n rhtas-demo-ci \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}{"\n"}'
```

### 5. Verify

```bash
export ISSUER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')

cosign verify \
  --certificate-identity-regexp='^https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/tekton-chains-builder$' \
  --certificate-oidc-issuer="$ISSUER" \
  quay.io/acme/rhtas-hello-world:tekton-<run-id>
```

## Key difference from Scenario 1

| | Jenkins (S1) | Tekton Chains (S2) |
|---|--------------|-------------------|
| cosign in pipeline | Yes — explicit stage | **No** |
| Signer identity | `rhtas-signer` SA | `tekton-chains-builder` SA |
| Failure mode | Pipeline fails at sign stage | TaskRun succeeds; check Chains annotation |
| Provenance | Optional | Chains generates `in-toto` attestation |

## Files

| File | Description |
|------|-------------|
| `openshift/pipeline.yaml` | Pipeline — build, SAST, push only |
| `openshift/tasks.yaml` | Reusable Tasks (git-clone, maven, semgrep, buildah) |
| `openshift/pipeline-sa.yaml` | Builder SA used by Chains signing identity |
| `openshift/scc-pipelines-builder.yaml` | Bind builder SA to `pipelines-scc` (buildah) |
| `openshift/chains-rhtas-patch.yaml` | Chains ↔ RHTAS configuration |
| `docs/tekton-chains-rhtas.md` | Deep dive on Chains + RHTAS |
