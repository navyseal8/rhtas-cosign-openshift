# Scenario 2 — Tekton pipeline with Tekton Chains (automatic signing)

Same build and SAST steps as Jenkins, but **no cosign step in the Pipeline**. [Tekton Chains](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/securing_openshift_pipelines/using-tekton-chains-to-sign-and-verify-image-and-provenance_using-tekton-chains-for-openshift-pipelines-supply-chain-security) observes completed TaskRuns and signs the pushed OCI image automatically.

## What this proves

- Supply-chain signing decoupled from pipeline authoring
- Chains configured to use **RHTAS Fulcio/Rekor** (keyless) instead of static `signing-secrets`
- Provenance (`in-toto`) stored alongside image signatures in Quay
- Same GitOps last mile as Scenario 1

## Flow

```
PipelineRun → maven build → SAST → buildah push → version-bump (commit newTag)
                    ↓                        ↓
         Tekton Chains (async)         Argo CD syncs rhtas-demo-dev
                    ↓
    Fulcio keyless sign + RHTAS Rekor
    (cert identity = tekton-chains-controller SA)
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

Fulcio must trust the **cluster ServiceAccount issuer** (in addition to Keycloak). Without this, Chains reaches Fulcio but gets `400 There was an error processing the identity token`:

```bash
oc patch securesign securesign-sample -n trusted-artifact-signer --type=json \
  --patch-file=openshift/fulcio-kubernetes-oidc-patch.json
# wait until Fulcio config includes kubernetes issuer:
oc get cm -n trusted-artifact-signer -l rhtas.redhat.com/resource=server-config \
  -o jsonpath='{.items[-1:].data.config\.yaml}{"\n"}'
```

Then configure Chains:

```bash
# ConfigMap only (safe to apply)
oc apply -f openshift/chains-rhtas-patch.yaml

# Patch the Operator-managed TektonConfig (do not oc create it)
oc patch tektonconfig config --type=merge \
  --patch-file=openshift/chains-tektonconfig-patch.yaml
```

Edit Fulcio/Rekor/TUF URLs and the OIDC issuer to match your cluster:

```bash
oc get fulcio,rekor,tuf -n trusted-artifact-signer
oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
```

This configures Chains to:

- Store OCI signatures in the registry (`artifacts.oci.storage: oci`)
- Enable transparency (`transparency.enabled: true`)
- Use **OIDC keyless signing** via Fulcio (`signers.x509.fulcio.*`)

See [docs/tekton-chains-rhtas.md](docs/tekton-chains-rhtas.md) for full explanation.

### 3. Run the pipeline

Create a GitHub PAT with **repo** write access (used for clone + GitOps commit):

```bash
oc create secret generic github-credentials \
  --from-literal=username=<github-user> \
  --from-literal=password=<github-pat> \
  -n rhtas-demo-ci
```

Link Quay credentials to the SA the PipelineRun will use. Console / default `tkn`
starts usually set `taskRunTemplate.serviceAccountName: pipeline`. Chains uses
**that** SA for Quay (not the workspace mount Buildah uses):

```bash
# Match the secret name you pass as docker-credentials below
oc secrets link pipeline quay-credentials \
  -n rhtas-demo-ci --for=pull,mount
# or: oc secrets link pipeline <your-quay-dockerconfig-secret> ...
```

```bash
tkn pipeline start rhtas-hello-world \
  -n rhtas-demo-ci \
  --param quay-org=rhn_support_jeretan \
  --param quay-repo=hello-world-cosign \
  --param git-url=https://github.com/navyseal8/rhtas-cosign-openshift.git \
  --param git-revision=main \
  --param gitops-url=https://github.com/navyseal8/rhtas-cosign-openshift.git \
  --param gitops-revision=main \
  --workspace name=shared-workspace,volumeClaimTemplateFile=openshift/workspace-pvc.yaml \
  --workspace name=docker-credentials,secret=quay-credentials \
  --workspace name=git-credentials,secret=github-credentials \
  --showlog
```

After `build-push`, **version-bump** updates `newTag` / `newName` in
`gitops/manifests/hello-world/kustomization.yaml` (and trust ConfigMap fields)
then pushes to `gitops-revision` so Argo CD syncs the new image.

For a **private** source repo the same `github-credentials` secret is reused on fetch-source.

### 4. Wait for Chains signature

```bash
oc get taskrun -n rhtas-demo-ci -l tekton.dev/pipelineTask=build-push \
  --sort-by=.metadata.creationTimestamp \
  -o go-template='{{range .items}}{{.metadata.name}} signed={{index .metadata.annotations "chains.tekton.dev/signed"}} transparency={{index .metadata.annotations "chains.tekton.dev/transparency"}}{{"\n"}}{{end}}' | tail -3
```

Expect `signed=true` and a transparency URL on your **RHTAS** Rekor (not `rekor.sigstore.dev`).

If you see `UNAUTHORIZED` / `signed=failed`, the TaskRun SA is missing the Quay
dockerconfig — see [docs/tekton-chains-rhtas.md](docs/tekton-chains-rhtas.md).

### 5. Verify (Cosign 3 + RHTAS trust)

Public Sigstore roots will fail against RHTAS. Initialize TUF once, create a trust
ConfigMap, then verify in-cluster:

```bash
NS=rhtas-demo-ci
export TUF_URL=$(oc get tuf -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json"

oc create configmap rhtas-trust -n "$NS" \
  --from-file=fulcio_v1.crt.pem="$HOME/.sigstore/root/targets/fulcio_v1.crt.pem" \
  --from-file=rekor.pub="$HOME/.sigstore/root/targets/rekor.pub" \
  --from-file=ctfe.pub="$HOME/.sigstore/root/targets/ctfe.pub" \
  --from-file=trusted_root.json="$HOME/.sigstore/root/targets/trusted_root.json" \
  --dry-run=client -o yaml | oc apply -f -

REKOR=$(oc get cm chains-config -n openshift-pipelines -o jsonpath='{.data.transparency\.url}')
# Prefer digest from the signed TaskRun:
IMAGE=quay.io/rhn_support_jeretan/hello-world-cosign@sha256:<IMAGE_DIGEST>

oc delete pod cosign-verify -n "$NS" --ignore-not-found
oc run cosign-verify -n "$NS" --restart=Never \
  --image=registry.access.redhat.com/hi/cosign:3.1.1 \
  --overrides="{
    \"spec\":{
      \"volumes\":[
        {\"name\":\"quay-auth\",\"secret\":{\"secretName\":\"quay-credentials\",\"items\":[{\"key\":\".dockerconfigjson\",\"path\":\"config.json\"}]}},
        {\"name\":\"trust\",\"configMap\":{\"name\":\"rhtas-trust\"}}
      ],
      \"containers\":[{
        \"name\":\"cosign-verify\",
        \"image\":\"registry.access.redhat.com/hi/cosign:3.1.1\",
        \"env\":[
          {\"name\":\"DOCKER_CONFIG\",\"value\":\"/.docker\"},
          {\"name\":\"SIGSTORE_ROOT_FILE\",\"value\":\"/var/run/trust/fulcio_v1.crt.pem\"},
          {\"name\":\"SIGSTORE_REKOR_PUBLIC_KEY\",\"value\":\"/var/run/trust/rekor.pub\"},
          {\"name\":\"SIGSTORE_CT_LOG_PUBLIC_KEY_FILE\",\"value\":\"/var/run/trust/ctfe.pub\"}
        ],
        \"volumeMounts\":[
          {\"name\":\"quay-auth\",\"mountPath\":\"/.docker\",\"readOnly\":true},
          {\"name\":\"trust\",\"mountPath\":\"/var/run/trust\",\"readOnly\":true}
        ],
        \"args\":[
          \"verify\",
          \"--rekor-url=${REKOR}\",
          \"--certificate-identity=https://kubernetes.io/namespaces/openshift-pipelines/serviceaccounts/tekton-chains-controller\",
          \"--certificate-oidc-issuer=https://kubernetes.default.svc\",
          \"${IMAGE}\"
        ]
      }]
    }
  }"

for i in $(seq 1 40); do
  ph=$(oc get pod cosign-verify -n "$NS" -o jsonpath='{.status.phase}')
  [[ "$ph" == "Succeeded" || "$ph" == "Failed" ]] && break
  sleep 2
done
oc logs -n "$NS" pod/cosign-verify
```

Common Cosign errors and the env vars that fix them are tabulated in
[docs/tekton-chains-rhtas.md](docs/tekton-chains-rhtas.md#troubleshooting).

## Key difference from Scenario 1

| | Jenkins (S1) | Tekton Chains (S2) |
|---|--------------|-------------------|
| cosign in pipeline | Yes — explicit stage | **No** |
| Signer identity (Fulcio Subject) | `rhtas-signer` SA | `tekton-chains-controller` SA |
| Failure mode | Pipeline fails at sign stage | TaskRun succeeds; check `chains.tekton.dev/signed` |
| Provenance | Optional | Chains generates `in-toto` attestation |

## Files

| File | Description |
|------|-------------|
| `openshift/pipeline.yaml` | Pipeline — build, SAST, push only |
| `openshift/tasks.yaml` | Reusable Tasks (git-clone, maven, semgrep, buildah, version-bump) |
| `openshift/pipeline-sa.yaml` | Builder SA used by Chains signing identity |
| `openshift/scc-pipelines-builder.yaml` | Bind builder SA to `pipelines-scc` (buildah) |
| `openshift/chains-rhtas-patch.yaml` | Chains env ConfigMap (Fulcio/Rekor/TUF) |
| `openshift/chains-tektonconfig-patch.yaml` | Merge-patch for TektonConfig `config` |
| `docs/tekton-chains-rhtas.md` | Deep dive on Chains + RHTAS |
