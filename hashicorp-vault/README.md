# HashiCorp Vault

[![App Status](https://argocd.local/api/badge?name=hashicorp-vault&revision=true)](https://argocd.local/applications/hashicorp-vault)
![Vault](https://img.shields.io/badge/HashiCorp_Vault-1.16.1-FFCF25?logo=vault&logoColor=black)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes&logoColor=white)

Secrets store for the homelab cluster. Vault runs in standalone mode (single pod) and serves as the single source of truth for all TLS certificates and application passwords. ExternalSecrets Operator reads from Vault and creates Kubernetes Secrets in each namespace automatically.

---

## Architecture

```
  ┌──────────────────┐      KV v2      ┌─────────────────────────┐
  │  generate-certs  │ ──────────────▶ │   HashiCorp Vault        │
  │  (WSL script)    │                 │   ClusterIP :8200         │
  └──────────────────┘                 │   ingress: vault.local    │
                                       └──────────┬──────────────┘
                          vault token             │
  ┌──────────────────┐ ◀────────────── │ ESO ClusterSecretStores   │
  │ ExternalSecrets  │                 │  vault-tls   (engine: tls)│
  │ Operator         │ ──────────────▶ │  vault-argocd (engine:    │
  └──────────────────┘  K8s Secrets    │              argocd)      │
                                       └───────────────────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │  Auto-unseal Deployment (vault-auto-unseal)                   │
  │  Polls vault status every 10s — runs "vault operator unseal" │
  │  if Vault wakes sealed after a pod restart                   │
  └──────────────────────────────────────────────────────────────┘
```

---

## Service Details

| Property | Value |
|---|---|
| Namespace | `hashicorp-vault` |
| Access | https://vault.local (nginx ingress at 192.168.56.22) |
| Service type | `ClusterIP` (port 8200) |
| UI | Enabled — same URL |
| Helm chart | `hashicorp/vault 0.29.1` |
| Unseal mode | Manual Shamir (1-of-1) + auto-unseal Deployment |

---

## Directory Structure

```
hashicorp-vault/
├── external-secrets/
│   └── vault-tls.yaml            # ExternalSecret: vault.local TLS cert from Vault
└── helm/
    └── hashicorp-vault/
        ├── Chart.yaml            # Umbrella chart (hashicorp/vault dependency)
        ├── values.yaml           # ClusterIP, nginx ingress, resource limits
        └── templates/
            └── auto-unseal.yaml  # Deployment that watches + unseals Vault
```

---

## Vault Engines

| Engine (KV v2) | Purpose | Secrets |
|---|---|---|
| `tls` | TLS certificates | `argocd`, `grafana`, `vault`, `zot` |
| `argocd` | App passwords | `admin` (password + server.secretkey) |

Each secret in `tls` has keys `tls.crt` and `tls.key`.

---

## First-Time Setup

> Vault is deployed by ArgoCD. After the pod is Running, run these steps once.

```bash
# 1. Initialize Vault (creates unseal key + root token)
kubectl exec -n hashicorp-vault hashicorp-vault-0 -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json \
  | tee ~/vault-init.json

# 2. Unseal manually (first time, before auto-unseal is configured)
kubectl exec -n hashicorp-vault hashicorp-vault-0 -- \
  vault operator unseal $(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)

# 3. Store the unseal key as a K8s Secret (used by auto-unseal Deployment)
kubectl create secret generic vault-unseal-key \
  --from-literal=key=$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json) \
  -n hashicorp-vault

# 4. Provide the root token to ESO
kubectl create secret generic vault-token \
  --namespace eso \
  --from-literal=token=$(jq -r '.root_token' ~/vault-init.json)

# 5. Populate Vault with certs + passwords
kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
# Run from the ArgoCD repo:
/mnt/c/Users/iacob/Documents/repos/ArgoCD/generate-certs.sh
```

---

## Auto-Unseal

The `templates/auto-unseal.yaml` Deployment runs a sidecar that polls Vault status every 10 seconds. If Vault is sealed (e.g. after a pod restart), it automatically runs `vault operator unseal` using the key stored in the `vault-unseal-key` Secret.

```bash
# Watch auto-unseal logs
kubectl logs -n hashicorp-vault -l app=vault-auto-unseal -f
```

---

## Vault CLI via Port-Forward

Vault is `ClusterIP` only — access from WSL via port-forward:

```bash
kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

# Check status
vault status

# Read a secret
vault kv get tls/argocd

# Write a secret
vault kv put tls/argocd tls.crt=@argocd.crt tls.key=@argocd.key
```

---

## Troubleshooting

**Vault pod CrashLoopBackOff / sealed after restart**
```bash
# Check auto-unseal logs
kubectl logs -n hashicorp-vault -l app=vault-auto-unseal

# Unseal manually if needed
kubectl exec -n hashicorp-vault hashicorp-vault-0 -- \
  vault operator unseal $(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)
```

**ExternalSecret shows SecretSyncedError**
```bash
# Verify Vault token secret exists in eso namespace
kubectl get secret vault-token -n eso

# Check ESO logs
kubectl logs -n eso -l app.kubernetes.io/name=external-secrets -f
```

**Lost vault-init.json**
> You cannot recover the unseal key or root token without re-initializing.
> Re-initializing destroys all stored secrets — re-run `generate-certs.sh` afterwards.
