# ArgoCD

[![App Status](https://argocd.local/api/badge?name=argocd&revision=true)](https://argocd.local/applications/argocd)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-Helm-EF7B4D?logo=argo&logoColor=white)
![GitOps](https://img.shields.io/badge/GitOps-App--of--Apps-brightgreen)

GitOps controller for the homelab Kubernetes cluster. ArgoCD watches Git repos and continuously reconciles the cluster state. All other services are deployed and managed through ArgoCD using the **App-of-Apps** pattern.

---

## Architecture

```
                    ┌──────────────────────────────────┐
                    │           Git Repos               │
                    │  App-of-apps / per-service repos  │
                    └──────────────┬───────────────────┘
                                   │ watches
                    ┌──────────────▼───────────────────┐
                    │            ArgoCD                 │
                    │   LoadBalancer: 192.168.56.20     │
                    │   https://argocd.local            │
                    └──┬───────┬───────┬───────┬───────┘
                       │       │       │       │  syncs
              ┌────────▼─┐ ┌───▼──┐ ┌──▼───┐ ┌▼──────┐
              │  Vault   │ │ ESO  │ │ nginx│ │  ...  │
              └──────────┘ └──────┘ └──────┘ └───────┘
```

**App-of-Apps bootstrap**: `bootstrap/app-of-apps.yaml` creates a single ArgoCD Application pointing at the [App-of-apps](https://github.com/Costel03/App-of-apps) repo's `apps/` folder with `directory.recurse: true`. ArgoCD discovers and deploys every `application.yaml` it finds there.

---

## Service Details

| Property | Value |
|---|---|
| Namespace | `argocd` |
| Access | https://argocd.local |
| LoadBalancer IP | `192.168.56.20` |
| Helm chart | `argo/argo-cd` |
| Admin password | from Vault (`argocd` engine, `admin` secret) |
| TLS cert | from Vault (`tls` engine, `argocd` secret) via ExternalSecret |

---

## Directory Structure

```
ArgoCD/
├── install.sh                    # Bootstrap script: installs ArgoCD + App-of-Apps
├── generate-certs.sh             # Generates CA + TLS certs, stores in Vault
├── bootstrap/
│   └── app-of-apps.yaml          # Root ArgoCD Application (App-of-Apps pattern)
├── external-secrets/
│   ├── argocd-admin.yaml         # ExternalSecret: admin password from Vault
│   └── argocd-tls.yaml           # ExternalSecret: TLS cert from Vault
└── helm/
    └── argocd/
        └── values.yaml           # Helm values (LoadBalancer .20, resources)
```

---

## Quick Start

> Prerequisites: cluster is up, `kubectl` works from WSL.

```bash
cd /mnt/c/Users/iacob/Documents/repos/ArgoCD
./install.sh
```

`install.sh` does the following:
1. Creates the `argocd` namespace
2. Installs ArgoCD via Helm
3. Waits for the `Application` CRD to be ready
4. Applies `bootstrap/app-of-apps.yaml` — ArgoCD takes over from here

### After Install — Full Bootstrap

```bash
# 1. Init + unseal Vault (first time only)
kubectl exec -n hashicorp-vault hashicorp-vault-0 -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json \
  | tee ~/vault-init.json

kubectl exec -n hashicorp-vault hashicorp-vault-0 -- \
  vault operator unseal $(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)

# 2. Create the ESO token secret
kubectl create secret generic vault-token \
  --namespace eso \
  --from-literal=token=$(jq -r '.root_token' ~/vault-init.json)

# 3. Create the auto-unseal key secret
kubectl create secret generic vault-unseal-key \
  --from-literal=key=$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json) \
  -n hashicorp-vault

# 4. Populate Vault with certs + passwords
kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
./generate-certs.sh

# 5. Force ExternalSecrets to sync
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite
```

---

## generate-certs.sh

Automates certificate management for the whole cluster:

- Generates a self-signed CA (`homelab-ca.crt`)
- Creates TLS certs for: `argocd.local`, `grafana.local`, `vault.local`, `zot.local`
- Stores each cert in Vault KV v2 (`tls` engine) so ExternalSecrets can distribute them to each namespace
- Sets the ArgoCD admin password + server secret key in Vault KV v2 (`argocd` engine)

Re-run any time you need to rotate certs or change passwords:

```bash
kubectl port-forward -n hashicorp-vault svc/hashicorp-vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
./generate-certs.sh
```

---

## Hosts File

Add to `C:\Windows\System32\drivers\etc\hosts` (Windows) or `/etc/hosts` (WSL):

```
192.168.56.20  argocd.local
192.168.56.21  grafana.local
192.168.56.22  vault.local
192.168.56.23  zot.local
```

---

## Troubleshooting

**ArgoCD UI unreachable**
```bash
kubectl get svc -n argocd argocd-server
# Check that EXTERNAL-IP is 192.168.56.20 (MetalLB must be healthy first)
```

**App stuck OutOfSync / degraded**
```bash
kubectl get applications -n argocd
argocd app sync <app-name> --force
```

**Admin password unknown**
```bash
# Before generate-certs.sh runs, use the initial secret:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

**ExternalSecrets not refreshing**
```bash
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite
```
