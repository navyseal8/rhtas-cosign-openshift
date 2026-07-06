#!/usr/bin/env bash
# Request a short-lived OIDC token for RHTAS/cosign keyless signing.
# Requires: oc logged in OR in-cluster SA with token create permissions.
set -euo pipefail

SA_NAMESPACE="${SA_NAMESPACE:-rhtas-demo-ci}"
SA_NAME="${SA_NAME:-rhtas-signer}"
AUDIENCE="${AUDIENCE:-sigstore}"
DURATION="${DURATION:-3600}"

if command -v oc &>/dev/null; then
  oc create token "$SA_NAME" \
    --namespace "$SA_NAMESPACE" \
    --audience "$AUDIENCE" \
    --duration "${DURATION}s"
else
  echo "oc not found; use in-cluster TokenRequest API" >&2
  exit 1
fi
