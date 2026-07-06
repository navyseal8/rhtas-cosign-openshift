# RHTAS Trusted Cosign on OpenShift — Demo Scenarios

Three end-to-end scenarios that prove [Red Hat Trusted Artifact Signer (RHTAS)](https://access.redhat.com/products/red-hat-trusted-artifact-signer) image signing on OpenShift, using the same sample application and GitOps deployment target.

| Scenario | Signing model | CI/CD | Cosign in pipeline? |
|----------|---------------|-------|---------------------|
| [1 — Jenkins](scenario-1-jenkins/README.md) | Explicit `cosign sign` with robot ServiceAccount | Jenkins on OpenShift | **Yes** — pipeline step after SAST |
| [2 — Tekton](scenario-2-tekton/README.md) | [Tekton Chains](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/) observes TaskRuns | OpenShift Pipelines | **No** — Chains signs after push |
| [3 — SPIFFE](scenario-3-spiffe/README.md) | Workload identity (JWT-SVID) via Zero Trust Workload Identity Manager | Tekton + SPIFFE-aware signer | **Automatic** — ambient identity token |

## Sample application

All scenarios build and deploy the same [Java hello-world app](apps/hello-world/) that reports:

- **Build version** — Jenkins build number, PipelineRun name, or Git commit
- **Signer identity** — Fulcio certificate identity from the cosign signature
- **Signature digest** — image digest at signing time

Runtime output example:

```json
{
  "message": "Hello from RHTAS demo",
  "buildVersion": "jenkins-42",
  "imageDigest": "sha256:abc123…",
  "signerIdentity": "https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer",
  "signedAt": "2026-06-05T10:15:00Z"
}
```

## Repository layout

```
├── apps/hello-world/          # Shared Maven + Dockerfile
├── docs/                      # Prerequisites, architecture, RHTAS baseline
├── scenario-1-jenkins/        # Jenkinsfile, SA/token guide, CI namespace
├── scenario-2-tekton/         # Pipeline, Tasks, Chains ↔ RHTAS config
├── scenario-3-spiffe/         # ClusterSPIFFEID, OIDC federation, ambient signing
└── gitops/                    # Argo CD / OpenShift GitOps — deploy on new image tag
```

## Prerequisites

See [docs/prerequisites.md](docs/prerequisites.md) for the full checklist. At minimum:

- OpenShift 4.17+ with cluster-admin access
- RHTAS Operator installed (`trusted-artifact-signer` namespace)
- Quay (or other OCI registry) with push/pull credentials
- OpenShift GitOps or Argo CD for the last-mile deploy
- Cluster `serviceAccountIssuer` configured (required for keyless / SA signing)

## Quick start (recommended order)

1. Deploy RHTAS and note Fulcio, Rekor, and TUF URLs — [docs/rhtas-setup.md](docs/rhtas-setup.md)
2. Configure GitOps to watch `gitops/manifests/hello-world` — [gitops/README.md](gitops/README.md)
3. Run **Scenario 1** (explicit cosign) to learn the token flow end-to-end
4. Run **Scenario 2** to compare with Tekton Chains (no cosign step in YAML)
5. Run **Scenario 3** for SPIFFE workload identity and automatic signing

## Image naming convention

```
quay.io/<org>/rhtas-hello-world:<scenario>-<version>
```

Examples:

- `quay.io/acme/rhtas-hello-world:jenkins-42`
- `quay.io/acme/rhtas-hello-world:tekton-abc12`
- `quay.io/acme/rhtas-hello-world:spiffe-def34`

GitOps watches the image tag in `gitops/manifests/hello-world/kustomization.yaml`. Each pipeline updates that tag and commits (or uses an Image Updater).

## Verification (all scenarios)

After deploy, verify the signature against RHTAS trust root:

```bash
export TUF_URL=$(oc get tuf -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')
export COSIGN_CERTIFICATE_OIDC_ISSUER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')

cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json"

cosign verify \
  --certificate-identity-regexp='^https://kubernetes.io/namespaces/.*/serviceaccounts/.*$' \
  --certificate-oidc-issuer="$COSIGN_CERTIFICATE_OIDC_ISSUER" \
  quay.io/<org>/rhtas-hello-world:<tag>
```

## References

- [RHTAS Deployment Guide](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/1/html/deployment_guide/index)
- [Securing OpenShift Pipelines — Tekton Chains](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/securing_openshift_pipelines/)
- [Zero Trust Workload Identity Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/security_and_compliance/zero-trust-workload-identity-manager)

## License

Apache 2.0 — see [LICENSE](LICENSE).
