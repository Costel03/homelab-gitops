# homelab-gitops

Everything running in the homelab cluster. ArgoCD watches this repo and syncs
it; nothing here is applied by hand.

The cluster itself — VMs, kubeadm, MetalLB, ArgoCD — is built by
[homelab-cluster](https://github.com/Costel03/homelab-cluster).

## Layout

One directory per tool. `app-of-apps` is the root Application that generates
all the others.

| Directory | What |
|---|---|
| `app-of-apps/` | Helm chart generating one ArgoCD Application per tool |
| `cert-manager/` | Issues and renews every TLS cert from the homelab CA |
| `argocd/` | ArgoCD's admin-password ExternalSecret and its Certificate |
| `hashicorp-vault/` | Vault + the auto-unseal Deployment |
| `external-secrets-operator/` | ESO and the Vault ClusterSecretStore |
| `nginx-ingress/` | Ingress controller |
| `nfs/` | nfs-subdir-external-provisioner |
| `monitoring/` | Prometheus, Loki, Grafana |
| `metrics-server/` | metrics-server |
| `vertical-pod-autoscaler/` | VPA |
| `my-app/` | My own app — nginx placeholder until it is written |

Each tool directory holds `helm/<name>/values.yaml` for the upstream chart,
plus `external-secrets/` or `templates/` for anything applied as raw manifests.
Charts are pulled from their upstream repositories — only values live here.

## Adding a tool

1. Create `<tool>/helm/<tool>/values.yaml`.
2. Add `app-of-apps/templates/<tool>.yaml` — copy an existing one; it points at
   the upstream chart and references `$values/<tool>/helm/<tool>/values.yaml`.
3. Add the toggle to `app-of-apps/values.yaml`.
4. Commit. ArgoCD syncs on its own.

Check it renders before committing:

```bash
helm template ao ./app-of-apps
```

## What is not here

MetalLB and the ArgoCD release are installed by `homelab-cluster`: ArgoCD's
Service is a LoadBalancer, so it stays Pending until MetalLB exists, and ArgoCD
cannot install itself. Managing them here too would mean two systems fighting
over one release.

The Zot registry runs in WSL on the host, not in the cluster — an in-cluster
registry cannot serve the images needed to start itself.

## Certificates

cert-manager owns all TLS. A self-signed ClusterIssuer mints the `homelab-ca`
Certificate, and a CA ClusterIssuer built from it signs one Certificate per
service — 90-day lifetime, renewed automatically 15 days before expiry. No
script regenerates certs any more.

Trust the CA once on the host:

```bash
make -C ../homelab-cluster trust-ca
```

## Secrets

None are committed. `argocd/seed-vault-secrets.sh` puts the admin passwords
into Vault; ESO reads them and writes Kubernetes Secrets. Vault's root token
and unseal key live in `~/vault-init.json` on the host.
