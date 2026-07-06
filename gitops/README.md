# GitOps — automatic deploy on image tag update

OpenShift GitOps (Argo CD) watches `gitops/manifests/hello-world/` and syncs to `rhtas-demo-dev` when CI updates the image tag.

## Flow

```
Jenkins/Tekton pipeline
    → push signed image to Quay
    → commit newTag to kustomization.yaml
    → Argo CD detects drift
    → rolls out Deployment in rhtas-demo-dev
```

## Setup

### 1. Create dev namespace

```bash
oc apply -f manifests/hello-world/namespace.yaml
```

### 2. Image pull secret in dev namespace

```bash
oc create secret docker-registry quay-pull \
  --docker-server=quay.io \
  --docker-username=<robot> \
  --docker-password=<token> \
  -n rhtas-demo-dev

oc secrets link default quay-pull --for=pull -n rhtas-demo-dev
```

### 3. Install OpenShift GitOps (if not present)

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 4. Register Application

```bash
oc apply -f applications/hello-world-dev.yaml
```

Update `spec.source.repoURL` to your GitHub repo URL.

### 5. Verify sync

```bash
oc get application hello-world-dev -n openshift-gitops
oc get pods -n rhtas-demo-dev
curl -s "https://$(oc get route hello-world -n rhtas-demo-dev -o jsonpath='{.spec.host}')/" | jq .
```

## What CI changes

Pipelines update only this file:

```yaml
# gitops/manifests/hello-world/kustomization.yaml
images:
  - name: quay.io/acme/rhtas-hello-world
    newName: quay.io/<org>/rhtas-hello-world
    newTag: jenkins-42   # or tekton-*, spiffe-*
```

Argo CD `automated` sync policy applies the new tag within ~3 minutes (or immediately on webhook).

## Optional — Argo CD Image Updater

Instead of pipeline git commits, use [Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/) to watch Quay tags matching `jenkins-*`, `tekton-*`, `spiffe-*`.

## Admission — only signed images

Combine with cluster policy to require RHTAS signatures before pods start in `rhtas-demo-dev`. See [docs/rhtas-setup.md](../docs/rhtas-setup.md).
