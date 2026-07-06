# Tekton Chains with RHTAS (keyless)

Tekton Chains is a controller in `openshift-pipelines` that watches TaskRuns. When a task pushes an OCI image, Chains:

1. Detects the image digest from TaskRun results/annotations
2. Generates provenance (default: `in-toto` format)
3. Signs the image and provenance
4. Pushes signatures to the same OCI registry (or Rekor)

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

File: `openshift/chains-rhtas-patch.yaml`

Key settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `artifacts.oci.storage` | `oci` | Signatures live in Quay next to image |
| `artifacts.oci.format` | `simplesigning` | OCI image signature format |
| `artifacts.taskrun.storage` | `oci` | Provenance stored in registry |
| `artifacts.taskrun.format` | `in-toto` | SLSA-compatible attestation |
| `transparency.enabled` | `true` | Upload to RHTAS Rekor |
| `signers.oci.fulcio.enabled` | `true` | Use Fulcio (not static key) |
| `signers.oci.x509.fulcio.provider` | `rhtas` | Point at in-cluster RHTAS |

Environment variables injected into the Chains controller tell cosign where RHTAS lives:

```yaml
COSIGN_FULCIO_URL: https://fulcio.<apps-domain>
COSIGN_REKOR_URL: https://rekor.<apps-domain>
COSIGN_MIRROR: https://tuf.<apps-domain>
COSIGN_OIDC_ISSUER: <cluster serviceAccountIssuer>
```

> **Note:** Exact `TektonConfig` schema varies by OpenShift Pipelines version. Validate against your installed version's Chains docs. The patch file includes comments for 1.14+ and may need field renames on older releases.

## ServiceAccount for signing identity

The build TaskRun uses `tekton-chains-builder` in `rhtas-demo-ci`. Chains uses **this SA's OIDC token** when calling Fulcio.

Fulcio certificate identity after signing:

```
https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/tekton-chains-builder
```

Ensure Fulcio trusts the cluster `serviceAccountIssuer` (same as Scenario 1).

## Registry authentication

Chains pushes signatures using credentials from the TaskRun's ServiceAccount:

```bash
oc secrets link tekton-chains-builder quay-credentials --for=pull,mount
```

The `build-push` task mounts `$(workspaces.dockerconfig.path)` for image push; Chains reuses the same credentials for signature blobs.

## Observing Chains

```bash
# Chains controller logs
oc logs -n openshift-pipelines -l app.kubernetes.io/part-of=tekton-chains --tail=50

# TaskRun annotation
oc get taskrun <name> -n rhtas-demo-ci -o yaml | grep chains.tekton.dev
```

Expected annotations:

```yaml
chains.tekton.dev/signed: "true"
chains.tekton.dev/type: image
```

## Verify image + attestation

```bash
export ISSUER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')
export IMAGE=quay.io/acme/rhtas-hello-world:tekton-abc12

cosign verify \
  --certificate-identity-regexp='^https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/tekton-chains-builder$' \
  --certificate-oidc-issuer="$ISSUER" \
  "$IMAGE"

cosign verify-attestation \
  --certificate-identity-regexp='^https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/tekton-chains-builder$' \
  --certificate-oidc-issuer="$ISSUER" \
  --type slsaprovenance \
  "$IMAGE"
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No `signed=true` after 5 min | Chains pod logs; image push result in TaskRun |
| `UNAUTHORIZED` on signature push | `oc secrets link` for builder SA |
| Fulcio error | RHTAS OIDC issuer config; Token audience |
| Wrong identity on verify | TaskRun `serviceAccountName` |

## Migration from static keys to RHTAS

If `signing-secrets` already exists from a prior lab:

1. Back up existing keys
2. Apply `chains-rhtas-patch.yaml`
3. Remove `artifacts.oci.signer: x509` key-based config
4. Restart Chains deployment in `openshift-pipelines`
