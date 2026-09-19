# External Secrets Operator

[![App Status](https://argocd.local/api/badge?name=ExternalSecretsOperator&revision=true)](https://argocd.local/applications/ExternalSecretsOperator)
![ESO](https://img.shields.io/badge/External_Secrets-Operator-6C47FF?logo=kubernetes&logoColor=white)
![Vault](https://img.shields.io/badge/Backend-HashiCorp_Vault-FFCF25?logo=vault&logoColor=black)

Bridges HashiCorp Vault and Kubernetes Secrets. ExternalSecrets Operator (ESO) watches `ExternalSecret` resources and automatically creates and refreshes Kubernetes Secrets by fetching values from Vault — no manual `kubectl create secret` needed for certificates or passwords.

---

## Architecture

```
  HashiCorp Vault (KV v2)
    ├── engine: tls    → argocd, grafana, vault, zot  (tls.crt, tls.key)
    └── engine: argocd → admin  (password, server.secretkey)
         │
         │  vault-token Secret (namespace: eso)
         ▼
  ┌──────────────────────────────────┐
  │  External Secrets Operator       │
  │  namespace: eso                  │
  │                                  │
  │  ClusterSecretStore: vault-tls   │  ─── reads engine: tls
  │  ClusterSecretStore: vault-argocd│  ─── reads engine: argocd
  └──────────────┬───────────────────┘
                 │  creates/updates
  ┌──────────────▼───────────────────┐
  │  Kubernetes Secrets              │
  │  (in each app namespace)         │
  │                                  │
  │  argocd-secret         (argocd)  │
  │  argocd-tls            (argocd)  │
  │  grafana-admin      (monitoring) │
  │  grafana-tls        (monitoring) │
  │  vault-tls    (hashicorp-vault)  │
  │  zot-tls   (container-registry) │
  └──────────────────────────────────┘
```

---

## Service Details

| Property | Value |
|---|---|
| Namespace | `eso` |
| Helm chart | `external-secrets/external-secrets` |
| CRD install | `installCRDs: true` |
| Vault token Secret | `vault-token` in namespace `eso` |

---

## Directory Structure

```
ExternalSecretsOperator/
├── vault-secretstore.yaml                 # (legacy) VaultSecretStore reference
├── external-secrets/
│   └── cluster-secret-store.yaml          # Two ClusterSecretStores: vault-tls + vault-argocd
└── helm/
    └── externalsecretoperator/
        ├── Chart.yaml                     # external-secrets/external-secrets chart
        └── values.yaml                    # replicaCount 1, installCRDs true
```

---

## ClusterSecretStores

Two cluster-scoped stores are defined in `external-secrets/cluster-secret-store.yaml`:

| Name | Vault Engine | Used For |
|---|---|---|
| `vault-tls` | `tls` (KV v2) | TLS certificates for all services |
| `vault-argocd` | `argocd` (KV v2) | Application passwords (ArgoCD, Grafana) |

Both authenticate with the `vault-token` Secret in the `eso` namespace.

---

## How It Works

Each service repo contains one or more `ExternalSecret` manifests. Example — Grafana TLS:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-tls
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-tls          # ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: grafana-tls        # K8s Secret to create
  data:
  - secretKey: tls.crt
    remoteRef:
      key: grafana           # Vault path within the engine
      property: tls.crt
  - secretKey: tls.key
    remoteRef:
      key: grafana
      property: tls.key
```

ESO reads this, fetches the values from Vault, and creates/updates the `grafana-tls` Secret in the `monitoring` namespace. It re-syncs every hour (or immediately on annotation change).

---

## First-Time Setup

```bash
# 1. Vault must be initialized and unsealed first (see hashicorp-vault README)

# 2. Create the vault-token secret for ESO
kubectl create secret generic vault-token \
  --namespace eso \
  --from-literal=token=$(jq -r '.root_token' ~/vault-init.json)

# 3. Apply ClusterSecretStores
kubectl apply -f external-secrets/cluster-secret-store.yaml

# 4. Force all ExternalSecrets to sync
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite
```

---

## Force Sync

```bash
# All ExternalSecrets cluster-wide
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite

# Single ExternalSecret
kubectl annotate externalsecret grafana-tls -n monitoring force-sync=$(date +%s) --overwrite
```

---

## Troubleshooting

**ExternalSecret shows `SecretSyncedError`**
```bash
# Check the specific ExternalSecret
kubectl describe externalsecret <name> -n <namespace>

# Check ESO controller logs
kubectl logs -n eso -l app.kubernetes.io/name=external-secrets -f
```

**`vault-token` secret missing / expired**
```bash
# Re-create it
kubectl delete secret vault-token -n eso
kubectl create secret generic vault-token \
  --namespace eso \
  --from-literal=token=$(jq -r '.root_token' ~/vault-init.json)
```

**ClusterSecretStore shows `Invalid`**
```bash
kubectl get clustersecretstores
kubectl describe clustersecretstore vault-tls
# Usually means Vault is sealed or vault-token is wrong
```
