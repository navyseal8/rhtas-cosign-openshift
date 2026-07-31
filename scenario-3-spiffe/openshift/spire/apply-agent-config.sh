#!/usr/bin/env bash
# Apply spire-agent ConfigMap with kubelet_url = node InternalIP.
# Run after SpireAgent is Ready (and create-only is set on the SpireAgent CR).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

: "${TRUST_DOMAIN:?Set TRUST_DOMAIN (usually apps domain)}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME (infrastructureName)}"

# Single-node / SNO: first node's InternalIP. Multi-node needs resolvable node DNS instead.
export NODE_IP="${NODE_IP:-$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
echo "Applying spire-agent ConfigMap with kubelet_url=https://${NODE_IP}:10250"

# Ensure create-only so the Operator does not revert this ConfigMap
oc annotate spireagent cluster ztwim.openshift.io/create-only=true --overwrite

envsubst < "${ROOT}/05-spire-agent-configmap.yaml" | oc apply -f -

oc delete pod -n zero-trust-workload-identity-manager \
  -l app.kubernetes.io/name=agent --ignore-not-found
oc delete pod -n zero-trust-workload-identity-manager \
  -l app.kubernetes.io/name=spiffe-oidc-discovery-provider --ignore-not-found

echo "Waiting for OIDC discovery provider..."
oc rollout status deployment/spire-spiffe-oidc-discovery-provider \
  -n zero-trust-workload-identity-manager --timeout=180s
