#!/bin/bash
#
# generate-certs.sh — Generate a self-signed CA + TLS certificates for
# argocd.local, grafana.local, vault.local, store everything in Vault,
# and set up admin passwords.
#
# Prerequisites:
#   - openssl, vault CLI, jq (optional)
#   - Vault is running and unsealed at the LoadBalancer IP
#   - VAULT_ADDR and VAULT_TOKEN environment variables are set
#
# Usage:
#   export VAULT_ADDR=http://192.168.56.22:8200
#   export VAULT_TOKEN=hvs.xxxxx
#   ./generate-certs.sh
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────
# Vault is ClusterIP — access via kubectl port-forward:
#   kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
VAULT_ADDR="${VAULT_ADDR:?Set VAULT_ADDR (e.g. http://127.0.0.1:8200 via port-forward)}"
VAULT_TOKEN="${VAULT_TOKEN:?Set VAULT_TOKEN}"

DOMAINS=("argocd" "grafana" "vault" "zot")
CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"' EXIT

echo "Vault:     $VAULT_ADDR"
echo "Cert dir:  $CERT_DIR"
echo ""

# ── Helper: Vault HTTP API ───────────────────────────────────────
vault_api() {
  local method="$1" path="$2"; shift 2
  curl -sf -X "$method" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    "$@" \
    "${VAULT_ADDR}/v1/${path}"
}

json_escape() {
  python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' < "$1"
}

# ── 1. Generate Root CA ─────────────────────────────────────────
echo "==> Generating Root CA …"
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes \
  -key "$CERT_DIR/ca.key" -sha256 -days 3650 \
  -out "$CERT_DIR/ca.crt" \
  -subj "/CN=Homelab Root CA/O=Homelab"
echo "    OK"

# ── 2. Generate per-domain certificates ─────────────────────────
for NAME in "${DOMAINS[@]}"; do
  FQDN="${NAME}.local"
  echo "==> Generating cert for ${FQDN} …"

  openssl genrsa -out "$CERT_DIR/${NAME}.key" 2048 2>/dev/null

  cat > "$CERT_DIR/${NAME}.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions     = v3
prompt             = no

[dn]
CN = ${FQDN}

[v3]
subjectAltName = DNS:${FQDN}
EOF

  openssl req -new \
    -key  "$CERT_DIR/${NAME}.key" \
    -out  "$CERT_DIR/${NAME}.csr" \
    -config "$CERT_DIR/${NAME}.cnf" 2>/dev/null

  openssl x509 -req \
    -in "$CERT_DIR/${NAME}.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/${NAME}.crt" \
    -days 825 -sha256 \
    -extfile "$CERT_DIR/${NAME}.cnf" -extensions v3 2>/dev/null

  # Full chain: leaf cert + CA cert
  cat "$CERT_DIR/${NAME}.crt" "$CERT_DIR/ca.crt" \
    > "$CERT_DIR/${NAME}-fullchain.crt"

  echo "    OK"
done

# ── 3. Enable Vault KV-v2 engines ───────────────────────────────
echo "==> Enabling Vault KV-v2 engines …"
vault_api POST "sys/mounts/tls" \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 \
  || echo "    tls engine already enabled"

vault_api POST "sys/mounts/argocd" \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 \
  || echo "    argocd engine already enabled"

# ── 4. Store TLS certs in Vault  (engine: tls) ──────────────────
for NAME in "${DOMAINS[@]}"; do
  echo "==> Storing TLS cert → tls/${NAME}"
  CRT=$(json_escape "$CERT_DIR/${NAME}-fullchain.crt")
  KEY=$(json_escape "$CERT_DIR/${NAME}.key")
  vault_api POST "tls/data/${NAME}" \
    -d "{\"data\":{\"tls.crt\":${CRT},\"tls.key\":${KEY}}}" >/dev/null
  echo "    OK"
done

# ── 5. Store admin credentials  (engine: argocd) ────────────────
echo ""
echo "── Admin credentials ──"

# ArgoCD admin
ARGOCD_PW="${ARGOCD_ADMIN_PASSWORD:-}"
if [ -z "$ARGOCD_PW" ]; then
  read -rsp "  ArgoCD  admin password: " ARGOCD_PW; echo
else
  echo "  ArgoCD admin password: [from ARGOCD_ADMIN_PASSWORD env]"
fi
SERVER_KEY=$(openssl rand -base64 32)
ARGOCD_PW_J=$(printf '%s' "$ARGOCD_PW" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
SERVER_KEY_J=$(printf '%s' "$SERVER_KEY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

echo "==> Storing → argocd/admin"
vault_api POST "argocd/data/admin" \
  -d "{\"data\":{\"password\":${ARGOCD_PW_J},\"server.secretkey\":${SERVER_KEY_J}}}" >/dev/null
echo "    OK"

# Grafana admin
GRAFANA_PW="${GRAFANA_ADMIN_PASSWORD:-}"
if [ -z "$GRAFANA_PW" ]; then
  read -rsp "  Grafana admin password: " GRAFANA_PW; echo
else
  echo "  Grafana admin password: [from GRAFANA_ADMIN_PASSWORD env]"
fi
GRAFANA_PW_J=$(printf '%s' "$GRAFANA_PW" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

echo "==> Storing → argocd/grafana"
vault_api POST "argocd/data/grafana" \
  -d "{\"data\":{\"username\":\"admin\",\"password\":${GRAFANA_PW_J}}}" >/dev/null
echo "    OK"

# Zot registry has no admin password (auth configured separately if needed)

# ── 6. Save CA cert for trust ───────────────────────────────────
CA_OUT="$HOME/homelab-ca.crt"
cp "$CERT_DIR/ca.crt" "$CA_OUT"

WIN_CA_PATH=$(wslpath -w "$CA_OUT" 2>/dev/null || echo "$CA_OUT")

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Done!  Certs + credentials stored in Vault."
echo ""
echo "  ExternalSecrets will pick them up automatically"
echo "  (TLS: up to 24h, admin creds: up to 1h)."
echo ""
echo "  To force immediate sync:"
echo "    kubectl annotate externalsecret -A --all force-sync=\$(date +%s) --overwrite"
echo ""
echo "  ── CA cert: $CA_OUT"
echo ""
echo "  ── Trust the CA ──"
echo ""
echo "  Windows (PowerShell as Administrator):"
echo "    Import-Certificate -FilePath '$WIN_CA_PATH' \\"
echo "      -CertStoreLocation 'Cert:\\LocalMachine\\Root'"
echo ""
echo "  WSL / Ubuntu:"
echo "    sudo cp $CA_OUT /usr/local/share/ca-certificates/homelab-ca.crt"
echo "    sudo update-ca-certificates"
echo ""
echo "  ── Hosts file ──"
echo "  Add to C:\\Windows\\System32\\drivers\\etc\\hosts (run notepad as Admin):"
  echo "    192.168.56.20  argocd.local"
  echo "    192.168.56.21  grafana.local"
  echo "    192.168.56.22  vault.local"
  echo "    192.168.56.23  zot.local"
echo ""
echo "  Browsers: restart after trusting the CA."
echo "══════════════════════════════════════════════════════════════"
