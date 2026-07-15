# Scenario 1 — Jenkins pipeline with explicit cosign signing

Jenkins builds the hello-world app, runs SAST, signs the container image with **cosign + RHTAS** using a dedicated **robot ServiceAccount**, pushes to Quay, and triggers GitOps.

## What this proves

- Keyless signing with OpenShift ServiceAccount OIDC tokens
- CI gate: SAST must pass before `cosign sign`
- Full audit trail: Fulcio certificate identity + Rekor transparency log
- GitOps deploy when image tag changes

## Flow

```
checkout → mvn test/package → SAST (semgrep) → docker build → push (unsigned)
    → cosign sign (SA token) → verify → update GitOps tag → commit
```

## Setup

### 1. Create CI namespace and ServiceAccount

```bash
oc apply -f openshift/namespace.yaml
oc apply -f openshift/serviceaccount-signer.yaml
oc apply -f openshift/rolebinding-tokenrequest.yaml
```

### 2. Configure RHTAS for kubernetes OIDC issuer

See [docs/rhtas-setup.md](../docs/rhtas-setup.md) — Fulcio must trust `spec.serviceAccountIssuer`.

### 3. Jenkins credentials

Create these in Jenkins (Manage Credentials):

| ID | Type | Purpose |
|----|------|---------|
| `quay-credentials` | Username/password | `docker login quay.io` |
| `gitops-repo` | SSH key or username/token | Push image tag updates |
| `openshift-token` | Secret text | Optional — `oc` from Jenkins if needed |

> **No cosign private key credential.** Signing uses ephemeral SA tokens (see [docs/cosign-service-account.md](docs/cosign-service-account.md)).

### 4. Jenkins agent ServiceAccount

The Jenkins Kubernetes cloud agent pod must run as `rhtas-signer` (or mount that SA). In OpenShift Jenkins:

- Set **Service Account** on the Pod template to `rhtas-signer`
- Mount `/var/run/secrets/openshift/serviceaccount/token` (default when SA is set)

### 5. Pipeline parameters

| Parameter | Example |
|-----------|---------|
| `QUAY_ORG` | `acme` |
| `QUAY_REPO` | `rhtas-hello-world` |
| `GITOPS_REPO` | `git@github.com:acme/rhtas-cosign-openshift-demos.git` |
| `GITOPS_BRANCH` | `main` |

### 6. Run

```bash
# Create Jenkins pipeline job pointing at scenario-1-jenkins/Jenkinsfile
# Build with parameters or multibranch from this repo
```

## Verify

```bash
# Signature on registry
cosign verify \
  --certificate-identity="https://kubernetes.io/namespaces/rhtas-demo-ci/serviceaccounts/rhtas-signer" \
  --certificate-oidc-issuer="$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')" \
  quay.io/<org>/rhtas-hello-world:jenkins-<BUILD_NUMBER>

# App deployed via GitOps
curl -s https://hello-world-rhtas-demo-dev.<apps-domain>/ | jq .
```

## Troubleshooting

### `process apparently never started in .../apps/hello-world@tmp/durable-...`

Git checkout succeeded; the failure is Jenkins **durable-task** unable to write shell wrapper scripts when `dir('apps/hello-world')` is combined with a **sidecar container** on OpenShift. The Jenkinsfile avoids `dir()` inside sidecars and sets `workingDir: /home/jenkins/agent` on all pod containers to match the jnlp agent.

### Checkout stage hangs on `git checkout -f`

Declarative pipelines run an **implicit checkout** before stages unless disabled. This Jenkinsfile sets `skipDefaultCheckout(true)` so only the `Checkout` stage runs `checkout scm` once. A duplicate checkout can leave `.git/index.lock` and appear to hang.

The `Selected Git installation does not exist` warning is harmless on Kubernetes agents as long as `git` is on the PATH in the jnlp container (your log shows `git version 2.30.2`).

If it persists, enable launch diagnostics on the Jenkins controller:

```text
-Dorg.jenkinsci.plugins.durabletask.BourneShellScript.LAUNCH_DIAGNOSTICS=true
```

### Maven `sh` step hangs for several minutes

Usually Maven is downloading dependencies with no visible output (`-q`), or cannot write to `~/.m2` when the builder sidecar runs as an OpenShift arbitrary UID. The Jenkinsfile sets a writable `HOME` and `maven.repo.local` under `/var/tmp/maven-home`, uses `-B -ntp -e` for logging, and the Red Hat `openshift` Maven profile.

If it still stalls, from a debug pod in `rhtas-demo-ci` check egress:

```bash
curl -sI https://repo.maven.apache.org/maven2/ | head -3
curl -sI https://maven.repository.redhat.com/ga/ | head -3
```

## Key documentation

- **[Cosign ServiceAccount & token flow](docs/cosign-service-account.md)** — step-by-step explanation of robot account, TokenRequest, and passing the token to cosign

## Files

| File | Description |
|------|-------------|
| `Jenkinsfile` | Full CI/CD pipeline |
| `openshift/serviceaccount-signer.yaml` | Robot SA `rhtas-signer` |
| `openshift/rolebinding-tokenrequest.yaml` | RBAC for TokenRequest API |
| `scripts/request-signing-token.sh` | Token helper used in pipeline |
