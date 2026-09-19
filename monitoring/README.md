# Monitoring

[![Grafana](https://argocd.local/api/badge?name=grafana&revision=true)](https://argocd.local/applications/grafana)
[![Prometheus](https://argocd.local/api/badge?name=prometheus&revision=true)](https://argocd.local/applications/prometheus)
[![Loki](https://argocd.local/api/badge?name=loki&revision=true)](https://argocd.local/applications/loki)
![Grafana](https://img.shields.io/badge/Grafana-11.x-F46800?logo=grafana&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-scrape_60s-E6522C?logo=prometheus&logoColor=white)
![Loki](https://img.shields.io/badge/Loki-SingleBinary-F5A800)

Full observability stack: **Prometheus** for metrics, **Loki** for logs, **Grafana** as the unified dashboard. All three are deployed as separate ArgoCD Applications from this repo.

---

## Architecture

```
  Kubernetes Nodes / Pods
         │ metrics (scrape)       │ logs (push)
         ▼                        ▼
  ┌─────────────┐         ┌──────────────┐
  │  Prometheus │         │     Loki     │
  │  ClusterIP  │         │  SingleBin.  │
  │  :9090      │         │  :3100       │
  └──────┬──────┘         └──────┬───────┘
         │  datasource            │  datasource
         └──────────┬─────────────┘
                    ▼
           ┌────────────────┐
           │    Grafana     │
           │ LoadBalancer   │
           │ 192.168.56.21  │
           │ :3000 (HTTPS)  │
           └────────────────┘
```

---

## Services

| Service | Namespace | Access | LoadBalancer IP |
|---|---|---|---|
| Grafana | `monitoring` | https://grafana.local | `192.168.56.21:3000` |
| Prometheus | `monitoring` | ClusterIP only (port 9090) | — |
| Loki | `monitoring` | ClusterIP only (port 3100) | — |

---

## Directory Structure

```
monitoring/
├── apps/
│   ├── grafana/application.yaml       # ArgoCD Application: grafana
│   ├── loki/application.yaml          # ArgoCD Application: loki
│   └── prometheus/application.yaml    # ArgoCD Application: prometheus
├── external-secrets/
│   ├── grafana-admin.yaml             # ExternalSecret: admin password from Vault
│   └── grafana-tls.yaml               # ExternalSecret: grafana.local TLS cert
└── helm/
    ├── grafana/
    │   ├── Chart.yaml                 # grafana/grafana chart
    │   └── values.yaml                # LoadBalancer .21, HTTPS, Vault secrets
    ├── loki/
    │   ├── Chart.yaml                 # grafana/loki chart
    │   └── values.yaml                # SingleBinary, 10Gi nfs-client PVC
    └── prometheus/
        ├── Chart.yaml                 # prometheus-community/prometheus chart
        └── values.yaml                # scrape_interval 60s, 15d retention
```

---

## Grafana

- **URL**: https://grafana.local (port 3000, HTTPS LoadBalancer)
- **Admin credentials**: pulled from Vault (`argocd` engine, `grafana` secret key `password`)
- **TLS**: cert from Vault (`tls` engine, `grafana` path) via ExternalSecret `grafana-tls`
- Pre-configured datasources: Prometheus + Loki

```bash
# Get admin password (if ESO is working)
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d && echo
```

## Prometheus

- **scrape_interval**: 60s (reduced from 15s to lower CPU on homelab)
- **retention**: 15 days
- Scrapes all pods with standard Prometheus annotations

## Loki

- **Mode**: SingleBinary (single replica, suitable for homelab)
- **Storage**: 10Gi PVC on `nfs-client` StorageClass
- Receives logs from Promtail / cluster log agents

---

## Secrets Flow

```
Vault KV v2
  argocd engine
    grafana secret → key: password
  tls engine
    grafana secret → keys: tls.crt, tls.key
         │
         ▼ (ExternalSecrets)
  K8s Secrets
    grafana-admin     (namespace: monitoring)
    grafana-tls       (namespace: monitoring)
         │
         ▼ (Grafana Helm chart)
  Grafana uses admin password + TLS cert
```

---

## Troubleshooting

**Grafana pod stuck in Init / CrashLoopBackOff**
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# Check secrets exist
kubectl get secret grafana-admin grafana-tls -n monitoring
```

**Grafana shows "Invalid username or password"**
```bash
# Force ExternalSecret to re-sync
kubectl annotate externalsecret grafana-admin -n monitoring force-sync=$(date +%s) --overwrite
```

**No metrics in Grafana**
```bash
# Verify Prometheus is up and scraped targets
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &
# Open http://localhost:9090/targets
```

**No logs in Grafana**
```bash
# Check Loki is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Check Loki PVC is bound
kubectl get pvc -n monitoring
```
