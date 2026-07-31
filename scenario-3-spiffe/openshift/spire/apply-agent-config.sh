#!/usr/bin/env bash
# Fix SPIRE agent kubelet DNS on lab/SNO clusters where node hostnames are not in CoreDNS.
#
# Root cause: agent does Get https://<nodeName>:10250/pods → "no such host"
# → OIDC discovery stays 0/1 ("no identity issued").
#
# Fix: enable Operator CREATE_ONLY_MODE (annotation alone is NOT enough), then add
# DaemonSet hostAliases: nodeName/Hostname → InternalIP.
set -euo pipefail

NS=zero-trust-workload-identity-manager
SUB_NS="$NS"
SUB_NAME=openshift-zero-trust-workload-identity-manager

echo "==> 1) Enable CREATE_ONLY_MODE on the Operator Subscription"
# Annotation ztwim.openshift.io/create-only is insufficient; the Operator env var is required.
# See OCP docs § Enabling create-only mode for ZTWIM.
if oc get sub "$SUB_NAME" -n "$SUB_NS" >/dev/null 2>&1; then
  oc -n "$SUB_NS" patch subscription "$SUB_NAME" --type=merge \
    -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
else
  echo "WARN: subscription $SUB_NAME not found in $SUB_NS — looking cluster-wide..."
  oc get sub -A | rg -i zero-trust || true
  SUB_LINE=$(oc get sub -A -o json | python3 -c '
import json,sys
for i in json.load(sys.stdin)["items"]:
  if "zero-trust" in i["metadata"]["name"]:
    print(i["metadata"]["namespace"], i["metadata"]["name"]); break
')
  if [[ -z "${SUB_LINE:-}" ]]; then
    echo "ERROR: cannot find ZTWIM subscription" >&2
    exit 1
  fi
  SUB_NS=${SUB_LINE%% *}; SUB_NAME=${SUB_LINE#* }
  oc -n "$SUB_NS" patch subscription "$SUB_NAME" --type=merge \
    -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
fi

echo "==> 2) Wait for create-only mode on SpireServer"
for i in $(seq 1 60); do
  reason=$(oc get spireserver cluster -o jsonpath='{.status.conditions[?(@.type=="CreateOnlyMode")].reason}' 2>/dev/null || true)
  # some versions use a different type name — also accept message match
  msg=$(oc get spireserver cluster -o json 2>/dev/null | python3 -c '
import json,sys
try:
  conds=json.load(sys.stdin).get("status",{}).get("conditions") or []
except Exception:
  conds=[]
for c in conds:
  t=(c.get("type") or "")+(c.get("reason") or "")+(c.get("message") or "")
  if "create-only" in t.lower() or "CreateOnly" in t:
    print(c.get("type"), c.get("status"), c.get("reason"), c.get("message")); break
' || true)
  env=$(oc get deploy -n "$NS" zero-trust-workload-identity-manager-controller-manager \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null | rg CREATE_ONLY || true)
  echo "  try=$i CREATE_ONLY env: ${env:-'(not yet)'} status: ${msg:-$reason}"
  if echo "$env" | rg -q 'CREATE_ONLY_MODE=true'; then
    # give controller a moment after env appears
    sleep 5
    break
  fi
  sleep 5
done

if ! oc get deploy -n "$NS" zero-trust-workload-identity-manager-controller-manager \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | rg -q 'CREATE_ONLY_MODE=true'; then
  echo "ERROR: CREATE_ONLY_MODE did not appear on the controller deploy. Aborting before patch so Operator will not wipe hostAliases." >&2
  exit 1
fi

echo "==> 3) Patch spire-agent DaemonSet hostAliases"
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
  hostnames=sorted({h for h in (name, addrs.get("Hostname")) if h})
  out.append({"ip": ip, "hostnames": hostnames})
  print(f"  {hostnames} -> {ip}", file=sys.stderr)
print(json.dumps(out))
')

oc patch daemonset spire-agent -n "$NS" --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":${HOST_ALIASES}}}}}"

# Verify patch stuck (Operator must not clear it under CREATE_ONLY_MODE)
sleep 3
HA=$(oc get ds spire-agent -n "$NS" -o jsonpath='{.spec.template.spec.hostAliases}')
if [[ -z "$HA" || "$HA" == "null" ]]; then
  echo "ERROR: hostAliases empty after patch — Operator still reconciling. Check CREATE_ONLY_MODE." >&2
  exit 1
fi
echo "  hostAliases OK: $HA"

echo "==> 4) Restart agent + OIDC pods"
oc delete pod -n "$NS" -l app.kubernetes.io/name=spire-agent --ignore-not-found
oc delete pod -n "$NS" -l app.kubernetes.io/name=spiffe-oidc-discovery-provider --ignore-not-found

echo "==> 5) Wait for OIDC Ready"
oc rollout status deployment/spire-spiffe-oidc-discovery-provider -n "$NS" --timeout=180s
oc get deploy,po -n "$NS" -l 'app.kubernetes.io/name in (spire-agent,spiffe-oidc-discovery-provider)'

echo
echo "Done. If this worked, leave CREATE_ONLY_MODE=true while you need hostAliases."
echo "To turn Operator reconciliation back on later (will wipe hostAliases unless RH adds a CR field):"
echo "  oc -n $SUB_NS patch subscription $SUB_NAME --type=merge -p '{\"spec\":{\"config\":{\"env\":[{\"name\":\"CREATE_ONLY_MODE\",\"value\":\"false\"}]}}}'"
