#!/usr/bin/env bash
# Checks that apply to the repo as a whole rather than to one app:
#   - the app-of-apps chart renders and every Application it generates is valid
#   - a local chart (chart.path) that changed since <base> has a new version,
#     because Zot and ArgoCD treat a published version as immutable
#
#   scripts/check-repo.sh [base-ref]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

base=${1:-}
mkdir -p "$OUT"

log "app-of-apps: lint and render"
helm lint "$APPS" --quiet
helm template apps "$APPS" --namespace argocd > "$OUT/applications.yaml"
yq -N 'select(.kind == "Application") | .metadata.name + "  " + (.spec.sources[0] | select(has("chart")) | .chart + " " + .targetRevision) // "(manifests only)"' \
  "$OUT/applications.yaml" | sed 's/^/    /' >&2

log "app-of-apps: validate"
mkdir -p "$OUT/.kubeconform-cache"
kubeconform -strict -summary \
  -kubernetes-version "$KUBE_VERSION" \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -cache "$OUT/.kubeconform-cache" \
  "$OUT/applications.yaml"

if [[ -n $base ]] && git rev-parse --quiet --verify "$base^{commit}" >/dev/null; then
  merge_base=$(git merge-base "$base" HEAD)
  status=0
  for f in "$APPS"/*/values.yaml; do
    app=$(basename "$(dirname "$f")")
    path=$(app_get "$app" .chart.path)
    [[ -n $path ]] || continue
    dir="apps/$app/$path"
    if git diff --quiet "$merge_base" HEAD -- "$dir"; then
      continue
    fi
    new=$(yq -r .version "$ROOT/$dir/Chart.yaml")
    old=$(git show "$merge_base:$dir/Chart.yaml" 2>/dev/null | yq -r .version || true)
    if [[ $new == "$old" ]]; then
      echo "::error file=$dir/Chart.yaml::$app: chart changed but version is still $new — bump it"
      status=1
    else
      log "$app: chart version ${old:-new} -> $new"
    fi
  done
  exit "$status"
fi
