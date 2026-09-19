#!/usr/bin/env bash
#
# seed-vault-secrets.sh — Put the admin passwords into Vault so the
# ExternalSecrets can resolve.
#
# TLS is no longer handled here. cert-manager issues and renews every
# certificate from the homelab CA (see cert-manager/issuers), so this only
# deals with passwords.
#
# Usage:
#   kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
#   ./seed-vault-secrets.sh
#
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:?Set VAULT_ADDR (e.g. http://127.0.0.1:8200 via port-forward)}"
VAULT_TOKEN="${VAULT_TOKEN:?Set VAULT_TOKEN}"

vault_api() {
  local method="$1" path="$2"; shift 2
  curl -sf -X "$method" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    "$@" \
    "${VAULT_ADDR}/v1/${path}"
}

json_str() { printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'; }

echo "Vault: $VAULT_ADDR"

echo "==> Enabling the argocd KV-v2 engine"
vault_api POST "sys/mounts/argocd" \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 \
  || echo "    already enabled"

ARGOCD_PW="${ARGOCD_ADMIN_PASSWORD:-}"
if [ -z "$ARGOCD_PW" ]; then
  read -rsp "  ArgoCD  admin password: " ARGOCD_PW; echo
fi

GRAFANA_PW="${GRAFANA_ADMIN_PASSWORD:-}"
if [ -z "$GRAFANA_PW" ]; then
  read -rsp "  Grafana admin password: " GRAFANA_PW; echo
fi

echo "==> Storing argocd/admin"
vault_api POST "argocd/data/admin" -d "{\"data\":{
  \"password\": $(json_str "$ARGOCD_PW"),
  \"server.secretkey\": $(json_str "$(openssl rand -base64 32)")
}}" >/dev/null

echo "==> Storing argocd/grafana"
vault_api POST "argocd/data/grafana" -d "{\"data\":{
  \"username\": \"admin\",
  \"password\": $(json_str "$GRAFANA_PW")
}}" >/dev/null

cat <<'EOF'

══════════════════════════════════════════════════════════════
  Passwords stored.

  Force an immediate ExternalSecrets sync:
    kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite

  The CA is issued by cert-manager, not by this script. Export and trust it:
    make -C ../homelab-cluster trust-ca
══════════════════════════════════════════════════════════════
EOF
