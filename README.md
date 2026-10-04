# homelab-gitops

Everything running in the homelab cluster, one directory per app. Every change
is rendered, validated and scanned by CI, its chart and images are published
to the Zot registry, and only then does ArgoCD sync it.

The cluster itself — VMs, kubeadm, Zot, the CI runner, MetalLB, ArgoCD — is
built by [homelab-cluster](https://github.com/Costel03/homelab-cluster).

## How a change reaches the cluster

1. Edit `apps/<app>/values.yaml` — a chart version, a value, `enabled`. Open a PR.
2. **ci** (GitHub-hosted runner) renders the chart with those values, validates
   every manifest against the Kubernetes 1.35 schemas, and scans every image
   the chart runs with Trivy.
3. Merge. **publish** (self-hosted runner in WSL) repeats the checks, then
   pushes the chart and the scanned images to Zot.
4. publish moves the `deployed` branch to that commit. ArgoCD watches only
   `deployed`, pulls the chart from Zot, and the nodes pull the images from Zot.

If any step fails, `deployed` does not move and the cluster keeps running the
last version that passed.

## Layout

| Path | What |
|---|---|
| `apps/<app>/values.yaml` | The one file per app: chart, version, namespace, sync wave, chart values |
| `apps/<app>/manifests/` | Raw manifests synced with the app (Certificates, ExternalSecrets, …) |
| `apps/my-app/chart/` | My own app's chart — packaged and pushed to Zot by CI |
| `apps/Chart.yaml`, `apps/templates/` | The app-of-apps: one ArgoCD Application per `values.yaml` |
| `apps/values.yaml` | Cluster-wide: this repo's URL, the tracked branch, Zot's address |
| `scripts/` | All CI logic. Workflows only call these, so they run locally too |
| `.trivyignore.yaml` | Vulnerabilities accepted on purpose, each with a reason |

## An app's values.yaml

```yaml
enabled: true
namespace: monitoring
syncWave: 0              # lower first; a wave waits until the one before is Healthy
chart:
  repository: https://grafana-community.github.io/helm-charts   # or oci://…
  name: loki
  version: 18.13.7
  # path: chart          # instead of the three above, for a chart in this repo
syncOptions: []          # optional, added to the Application's sync options
ignoreDifferences: []    # optional, passed to the Application as-is
values:                  # handed to the chart unchanged
  deploymentMode: Monolithic
```

## Apps

| App | Namespace | Wave | Chart |
|---|---|---:|---|
| `cert-manager` | cert-manager | -2 | jetstack `cert-manager` |
| `nfs` | kube-system | -1 | kubernetes-csi `csi-driver-nfs` — the `nfs-client` StorageClass |
| `metrics-server` | kube-system | -1 | `metrics-server` |
| `traefik` | traefik | 0 | `traefik` — ingress on 192.168.56.22 |
| `vertical-pod-autoscaler` | vpa-system | 0 | kubernetes/autoscaler `vertical-pod-autoscaler` |
| `prometheus` | monitoring | 0 | prometheus-community `prometheus` |
| `loki` | monitoring | 0 | grafana-community `loki` |
| `my-app` | my-app | 0 | `apps/my-app/chart` |
| `hashicorp-vault` | hashicorp-vault | 1 | hashicorp `vault` (Vault 2.0) |
| `external-secrets` | eso | 2 | `external-secrets` |
| `argocd-config` | argocd | 3 | manifests only: ArgoCD's certificate and admin password |
| `grafana` | monitoring | 3 | grafana-community `grafana` |

Waves only order apps because homelab-cluster gives ArgoCD a health check for
Applications. `argocd-config` and `grafana` are last because they wait for
Vault to be seeded.

## Adding or upgrading an app

| To | Do |
|---|---|
| Upgrade | Change `chart.version` (and any values the new version needs) |
| Add | Create `apps/<name>/values.yaml` — copy a similar one |
| Remove | `enabled: false`, or delete the directory |
| Change my-app | Edit `apps/my-app/chart/` **and** bump its `Chart.yaml` version — CI rejects the PR otherwise |

Run the same checks locally before pushing:

```bash
export PATH="$(.github/actions/setup-tools/install.sh):$PATH"   # pinned tools
scripts/check-repo.sh origin/main     # app-of-apps renders, Applications valid
scripts/app.sh check loki             # render, validate, scan one app
```

## The scan gate

Trivy fails an app when one of its images has a **CRITICAL vulnerability with a
fix available** — there is a newer image to move to. Set `FAIL_ON=HIGH` in
`scripts/lib.sh` to be stricter. To accept a finding, add it to
`.trivyignore.yaml` with a statement and an expiry. Every image is scanned by
digest for `linux/amd64`, and that exact digest is what gets copied, so a tag
that moves upstream between scan and push cannot slip through.

`ci` also re-scans everything weekly, because new CVEs land in images that
have not changed.

## Zot

| What | Where | Written by |
|---|---|---|
| Charts | `192.168.56.1:5000/charts/<name>:<version>` | publish |
| Scanned images | `192.168.56.1:5000/scanned/<registry>/<repo>:<tag>` | publish |
| Cache | `192.168.56.1:5000/<registry>/<repo>:<tag>` | Zot, on demand |

Images keep their upstream names in the charts. containerd on the nodes asks
Zot's `scanned/` copy first, then the cache, then the upstream — so what runs
is the digest that was scanned. The two image paths stay separate because any
lookup of a missing tag in the cache makes Zot fetch it from upstream into
that same tag. Images CI never publishes (kube-system, Calico, MetalLB, ArgoCD)
come through the cache; Zot scans those too, at `http://192.168.56.1:5000`.

## GitHub settings this relies on

| Setting | Why |
|---|---|
| Settings > Actions > General > *Require approval for all external contributors* | The self-hosted runner can push to Zot. A fork's PR could edit a workflow to target it; approval means nothing from a fork runs until you have read it. |
| Branch protection on `main` requiring the `ci` checks | Optional; makes the gate mandatory for your own PRs too. |
| Nobody pushes to `deployed` but the publish workflow | ArgoCD deploys whatever is there. |

## Secrets

None are committed. `scripts/seed-vault-secrets.sh` puts the ArgoCD and
Grafana admin passwords into Vault; ESO copies them into Kubernetes Secrets.
Vault's root token and unseal key live in `~/vault-init.json` on the host.

## Certificates

cert-manager owns all TLS. A self-signed ClusterIssuer mints the `homelab-ca`
Certificate, and a CA ClusterIssuer built from it signs one Certificate per
service — 90 days, renewed 15 days before expiry. Trust the CA once on the
host with `make -C ../homelab-cluster trust-ca`.

## What is not here

MetalLB and the ArgoCD release are installed by homelab-cluster: ArgoCD's
Service is a LoadBalancer, so it stays Pending until MetalLB exists, and ArgoCD
cannot install itself. Zot runs in WSL on the host — an in-cluster registry
cannot serve the images needed to start itself.
