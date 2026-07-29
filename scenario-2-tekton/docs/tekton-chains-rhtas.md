# Tekton Chains with RHTAS (keyless)

Tekton Chains is a controller in `openshift-pipelines` that watches TaskRuns. When a task pushes an OCI image, Chains:

1. Detects the image digest from TaskRun results/annotations
2. Generates provenance (default: `in-toto` format)
3. Signs the image and provenance
4. Pushes signatures to the same OCI registry (and logs to Rekor)

## Why no cosign in the Pipeline YAML?

Chains **replaces** the manual `cosign sign` step. Pipeline authors focus on build/test/push; the platform owns signing policy centrally.

This is the main contrast with Scenario 1.

## Chains configuration for RHTAS

Traditional OpenShift Pipelines docs use a static key in `signing-secrets`:

```bash
cosign generate-key-pair k8s://openshift-pipelines/signing-secrets
```

For RHTAS we use **keyless signing** with Fulcio — same trust model as Jenkins Scenario 1.

### TektonConfig patch (summary)

Files:

- `openshift/chains-rhtas-patch.yaml` — ConfigMap with Cosign/RHTAS env
- `openshift/chains-tektonconfig-patch.yaml` — merge-patch for existing `TektonConfig/config`

```bash
oc apply -f openshift/chains-rhtas-patch.yaml
oc patch tektonconfig config --type=merge \
  --patch-file=openshift/chains-tektonconfig-patch.yaml
```

Do **not** `oc create` a new `TektonConfig` — the Operator already manages `config`, and a partial create fails with `missing field(s): spec.targetNamespace`.

Key settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `artifacts.oci.storage` | `oci` | Signatures live in Quay next to image |
| `artifacts.oci.format` | `simplesigning` | OCI image signature format |
| `artifacts.taskrun.storage` | `oci` | Provenance stored in registry |
| `artifacts.taskrun.format` | `in-toto` | SLSA-compatible attestation |
| `transparency.enabled` | `true` | Upload to RHTAS Rekor |
| `transparency.url` | RHTAS Rekor Ready URL | **Required** — otherwise Chains uses public `rekor.sigstore.dev` |
| `signers.x509.fulcio.enabled` | `true` | Use Fulcio (not static key) |
| `signers.x509.fulcio.address` | Fulcio Ready URL | Route host (not in-cluster DNS) |
| `signers.x509.fulcio.issuer` | `https://kubernetes.default.svc` | Must match Fulcio kubernetes OIDC issuer |

> **Note:** The supplemental `chains-rhtas-env` ConfigMap is **not** mounted into the controller. TektonConfig fields (and the operator-managed `chains-config` ConfigMap) are what matter.

## ServiceAccount for signing identity

**Fulcio certificate Subject** (what Cosign verifies) is the Chains **controller**:

```
https://kubernetes.io/namespaces/openshift-pipelines/serviceaccounts/tekton-chains-controller
```

OIDC issuer in the cert is whatever Fulcio was configured with for kubernetes tokens — typically:

```
https://kubernetes.default.svc
```

(not always `Authentication.spec.serviceAccountIssuer`).

The build TaskRun SA is used for **Quay registry auth** (Chains reads that SA’s dockerconfig secrets via the API). It is **not** the Fulcio identity.

Ensure Fulcio trusts the cluster SA issuer with `Type: kubernetes` and `ClientID: sigstore` (see `fulcio-kubernetes-oidc-patch.json`).

## Registry authentication (most common `signed=failed` cause)

Chains uploads OCI signatures by authenticating as the **TaskRun** ServiceAccount. Buildah push working is not enough — Buildah often uses a **workspace-mounted** secret, while Chains only sees secrets **linked to the TaskRun SA**.

### Which SA?

Tekton v1 drops Pipeline task-level `serviceAccountName`. The PipelineRun’s `taskRunTemplate.serviceAccountName` wins. OpenShift Console / default `tkn` starts often use:

```yaml
taskRunTemplate:
  serviceAccountName: pipeline   # ← Chains uses THIS for Quay
```

Check:

```bash
oc get taskrun -n rhtas-demo-ci -l tekton.dev/pipelineTask=build-push \
  -o jsonpath='{range .items[*]}{.metadata.name} sa={.spec.serviceAccountName}{"\n"}{end}' | tail -3
```

Link the **same** dockerconfig secret the PipelineRun mounts as `docker-credentials` to that SA:

```bash
# If TaskRun SA is pipeline (common):
oc secrets link pipeline <quay-dockerconfig-secret> \
  -n rhtas-demo-ci --for=pull,mount

# If you start with --serviceaccount=tekton-chains-builder:
oc secrets link tekton-chains-builder <quay-dockerconfig-secret> \
  -n rhtas-demo-ci --for=pull,mount
```

Optional (controller copy):

```bash
oc get secret <quay-dockerconfig-secret> -n rhtas-demo-ci -o yaml \
  | sed 's/namespace: rhtas-demo-ci/namespace: openshift-pipelines/' \
  | grep -v 'resourceVersion\|uid\|creationTimestamp\|ownerReferences' \
  | oc apply -f -
oc secrets link tekton-chains-controller <quay-dockerconfig-secret> \
  -n openshift-pipelines --for=pull,mount
```

Typical failure:

```text
getting signed image: GET https://quay.io/v2/.../manifests/sha256:...: UNAUTHORIZED
→ chains.tekton.dev/signed=failed
```

Rekor may still show a transparency URL (attestation logged) while OCI signature push fails. Cosign then reports **no signatures found**.

Older TaskRuns stay `signed=failed`; only **new** runs after linking the secret will become `signed=true`.

## Buildah SCC (`PodAdmissionFailed`)

Buildah needs `pipelines-scc` with `SETFCAP` and `allowPrivilegeEscalation: true`. If the operator resets the SCC:

```bash
oc patch scc pipelines-scc --type merge -p \
  '{"allowedCapabilities":["SETFCAP"],"allowPrivilegeEscalation":true}'
```

Symptom:

```text
provider pipelines-scc: .containers[0].allowPrivilegeEscalation: Invalid value: true
```

Also grant the SA that actually runs the TaskRun (e.g. `pipeline` or `tekton-chains-builder`) use of `pipelines-scc`.

## Transparency log (RHTAS Rekor)

```bash
oc patch tektonconfig config --type=merge --patch-file=openshift/chains-tektonconfig-patch.yaml
oc get cm chains-config -n openshift-pipelines -o yaml | grep transparency
# must show transparency.url pointing at your RHTAS Rekor route
```

## Observing Chains

```bash
oc logs -n openshift-pipelines -l app.kubernetes.io/part-of=tekton-chains --tail=50

oc get taskrun -n rhtas-demo-ci -l tekton.dev/pipelineTask=build-push \
  --sort-by=.metadata.creationTimestamp \
  -o go-template='{{range .items}}{{.metadata.name}} signed={{index .metadata.annotations "chains.tekton.dev/signed"}} transparency={{index .metadata.annotations "chains.tekton.dev/transparency"}}{{"\n"}}{{end}}' | tail -5
```

Expected:

```yaml
chains.tekton.dev/signed: "true"
chains.tekton.dev/transparency: https://rekor-server-.../api/v1/log/entries?logIndex=N
```

## Verify image (Cosign 3 + RHTAS)

Public Sigstore trust roots do **not** validate RHTAS-issued certs or Rekor SETs. Cosign 3.x needs RHTAS trust material (or a prior `cosign initialize` against the RHTAS TUF mirror).

### 1. Fetch TUF targets (once per workstation)

```bash
export TUF_URL=$(oc get tuf -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json"
# populates ~/.sigstore/root/targets/{fulcio_v1.crt.pem,rekor.pub,ctfe.pub,trusted_root.json,...}
```

### 2. Create an in-cluster trust ConfigMap

```bash
NS=rhtas-demo-ci
oc create configmap rhtas-trust -n "$NS" \
  --from-file=fulcio_v1.crt.pem="$HOME/.sigstore/root/targets/fulcio_v1.crt.pem" \
  --from-file=rekor.pub="$HOME/.sigstore/root/targets/rekor.pub" \
  --from-file=ctfe.pub="$HOME/.sigstore/root/targets/ctfe.pub" \
  --from-file=trusted_root.json="$HOME/.sigstore/root/targets/trusted_root.json" \
  --dry-run=client -o yaml | oc apply -f -
```

### 3. Verify in-cluster (hardened Cosign image)

```bash
NS=rhtas-demo-ci
REKOR=$(oc get cm chains-config -n openshift-pipelines -o jsonpath='{.data.transparency\.url}')
IMAGE=quay.io/<org>/<repo>@sha256:<digest>   # prefer digest from TaskRun IMAGE_DIGEST

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

# wait for Succeeded/Failed (Ready is wrong — verify pods exit)
for i in $(seq 1 40); do
  ph=$(oc get pod cosign-verify -n "$NS" -o jsonpath='{.status.phase}')
  [[ "$ph" == "Succeeded" || "$ph" == "Failed" ]] && break
  sleep 2
done
oc logs -n "$NS" pod/cosign-verify
```

Success looks like:

```text
Subject: https://kubernetes.io/namespaces/openshift-pipelines/serviceaccounts/tekton-chains-controller
Issuer:  https://kubernetes.default.svc
```

`--rekor-url` may print a Cosign 3 deprecation warning; it still works when paired with the RHTAS Rekor public key.

### Local Cosign 2.x (after `cosign initialize`)

```bash
export DOCKER_CONFIG=...   # quay dockerconfig dir
export SIGSTORE_REKOR_PUBLIC_KEY="$HOME/.sigstore/root/targets/rekor.pub"
export REKOR=$(oc get cm chains-config -n openshift-pipelines -o jsonpath='{.data.transparency\.url}')

cosign verify \
  --rekor-url="$REKOR" \
  --certificate-identity=https://kubernetes.io/namespaces/openshift-pipelines/serviceaccounts/tekton-chains-controller \
  --certificate-oidc-issuer=https://kubernetes.default.svc \
  "$IMAGE"
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `PodAdmissionFailed` / `allowPrivilegeEscalation` / `SETFCAP` | Patch `pipelines-scc` (`SETFCAP` + `allowPrivilegeEscalation: true`); bind the TaskRun SA to that SCC |
| Pipeline succeeds, `signed=failed`, event `UNAUTHORIZED` on quay.io | Link the PipelineRun’s Quay dockerconfig secret to the **TaskRun SA** (`pipeline` or `tekton-chains-builder`) |
| `signed=failed` + transparency on `rekor.sigstore.dev` | Set `transparency.url` to RHTAS Rekor on TektonConfig |
| Fulcio `400` / `error processing the identity token` | Add kubernetes OIDC issuer (`ClientID: sigstore`) via `fulcio-kubernetes-oidc-patch.json` |
| Fulcio DNS / no such host | Use Fulcio **Ready route** URL in `signers.x509.fulcio.address` |
| `no signatures found` | Task must emit **both** `IMAGE_URL` and `IMAGE_DIGEST`; and Chains must have Quay auth (`signed=true`) |
| Verify: `signature not found in transparency log` | Point Cosign at RHTAS Rekor (`--rekor-url`) + provide `SIGSTORE_REKOR_PUBLIC_KEY` (or TUF init) |
| Verify: `certificate signed by unknown authority` / `SIGSTORE_ROOT_FILE` | Mount RHTAS `fulcio_v1.crt.pem` (from TUF targets) |
| Verify: `ctfe public key not found` | Mount RHTAS `ctfe.pub` as `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE` |
| Verify identity mismatch | Expect `tekton-chains-controller`, issuer `https://kubernetes.default.svc` |
| Old TaskRuns still `signed=failed` after fix | Expected — Chains does not re-sign; start a new PipelineRun |

## Migration from static keys to RHTAS

If `signing-secrets` already exists from a prior lab:

1. Back up existing keys
2. Apply `chains-rhtas-patch.yaml` and patch `TektonConfig` with `chains-tektonconfig-patch.yaml`
3. Remove key-based signer config if switching from static keys
4. Restart Chains deployment in `openshift-pipelines`
