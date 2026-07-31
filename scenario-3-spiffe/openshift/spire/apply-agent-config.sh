#!/usr/bin/env bash
# Make SPIRE agent resolve node hostnames via pod hostAliases (lab/SNO fix).
# Run after SpireAgent DaemonSet exists.
#
# Why not agent.conf kubelet_url?
#   SpireAgent CR cannot set it; Operator often regenerates spire-agent ConfigMap
#   and drops manual kubelet_url. hostAliases keeps the Operator's agent.conf.
set -euo pipefail

NS=zero-trust-workload-identity-manager

echo "Enabling create-only so the Operator will not wipe DaemonSet hostAliases..."
oc annotate spireagent cluster ztwim.openshift.io/create-only=true --overwrite
oc annotate zerotrustworkloadidentitymanager cluster ztwim.openshift.io/create-only=true --overwrite 2>/dev/null || true

# Build hostAliases for every node: Hostname/Nodename → InternalIP
HOST_ALIASES=$(oc get nodes -o json | python3 -c '
import json,sys
nodes=json.load(sys.stdin)["items"]
out=[]
for n in nodes:
  name=n["metadata"]["name"]
  addrs={a["type"]:a["address"] for a in n.get("status",{}).get("addresses",[])}
  ip=addrs.get("InternalIP")
  if not ip:
    raise SystemExit(f"no InternalIP for node {name}")
  hostnames=sorted({name, addrs.get("Hostname") or name})
  out.append({"ip": ip, "hostnames": hostnames})
  print(f"  {hostnames} -> {ip}", file=sys.stderr)
print(json.dumps(out))
')

echo "Patching DaemonSet spire-agent hostAliases..."
oc patch daemonset spire-agent -n "$NS" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":${HOST_ALIASES}}}}}"

echo "Restarting agent + OIDC pods (label is spire-agent, not agent)..."
oc delete pod -n "$NS" -l app.kubernetes.io/name=spire-agent --ignore-not-found
oc delete pod -n "$NS" -l app.kubernetes.io/name=spiffe-oidc-discovery-provider --ignore-not-found

echo "Waiting for OIDC discovery provider..."
oc rollout status deployment/spire-spiffe-oidc-discovery-provider -n "$NS" --timeout=180s
oc get deploy,po -n "$NS" -l 'app.kubernetes.io/name in (spire-agent,spiffe-oidc-discovery-provider)'
