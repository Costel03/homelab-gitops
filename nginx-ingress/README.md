# nginx-ingress

[![App Status](https://argocd.local/api/badge?name=nginx-ingress&revision=true)](https://argocd.local/applications/nginx-ingress)
[![App Status](https://argocd.local/api/badge?name=nginx-ingress-zot&revision=true)](https://argocd.local/applications/nginx-ingress-zot)
![NGINX](https://img.shields.io/badge/NGINX_Ingress-4.12.1-009639?logo=nginx&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes&logoColor=white)

Two NGINX Ingress Controllers — each with a dedicated MetalLB LoadBalancer IP — providing TLS termination and HTTP→HTTPS redirect for the homelab services.

---

## Architecture

```
  Windows Host
      │
      ├── 192.168.56.22  ──▶  nginx-ingress (class: nginx)
      │                            └── vault.local  ──▶  hashicorp-vault:8200
      │
      └── 192.168.56.23  ──▶  nginx-ingress-zot (class: nginx-zot)
                                   └── zot.local    ──▶  zot:5000
```

Two separate controller instances means each hostname gets its own LoadBalancer IP. TLS is terminated at the controller using certs stored as Kubernetes Secrets (sourced from Vault via ExternalSecrets).

---

## Controllers

| Name | IngressClass | LoadBalancer IP | Routes |
|---|---|---|---|
| `nginx-ingress` | `nginx` (default) | `192.168.56.22` | `vault.local` |
| `nginx-ingress-zot` | `nginx-zot` | `192.168.56.23` | `zot.local` |

---

## Directory Structure

```
nginx-ingress/
└── helm/
    └── nginx-ingress/
        ├── Chart.yaml    # ingress-nginx 4.12.1
        └── values.yaml   # LoadBalancer .22, class nginx (default)
```

---

## Key Configuration

All Ingress resources use `nginx.ingress.kubernetes.io/ssl-redirect: "true"`. Backend services run plain HTTP; TLS is terminated at nginx.

**nginx-ingress** (`helm/nginx-ingress/values.yaml`)
```yaml
controller:
  service:
    annotations:
      metallb.universe.tf/loadBalancerIPs: "192.168.56.22"
  ingressClassResource:
    name: nginx
    default: true   # catches any Ingress without an explicit class
```

**nginx-ingress-zot** (`helm/nginx-ingress-zot/values.yaml`)
```yaml
controller:
  service:
    annotations:
      metallb.universe.tf/loadBalancerIPs: "192.168.56.23"
  ingressClassResource:
    name: nginx-zot
    default: false
```

---

## Adding a New Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx          # or nginx-zot
  rules:
  - host: my-app.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 8080
  tls:
  - secretName: my-app-tls
    hosts:
    - my-app.local
```

---

## Troubleshooting

**Ingress ADDRESS is empty**
```bash
# The ingress controller LoadBalancer must have an IP first
kubectl get svc -n ingress-nginx
kubectl get svc -n ingress-nginx-zot

# MetalLB must be healthy
kubectl get pods -n metallb-system
```

**502 Bad Gateway**
```bash
# Check backend service is running + reachable
kubectl get endpoints -n <namespace> <service-name>

# Check nginx logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

**TLS cert not working / browser warning**
```bash
# Verify the TLS secret exists in the correct namespace
kubectl get secret <tls-secret> -n <namespace>

# Force ExternalSecrets to re-sync the cert
kubectl annotate externalsecret <name> -n <namespace> force-sync=$(date +%s) --overwrite
```
