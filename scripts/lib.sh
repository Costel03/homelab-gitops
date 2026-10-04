#!/usr/bin/env bash
# Shared by the CI scripts. Sourced, not run.
#
# Needs helm, yq, crane, kubeconform, trivy and jq on PATH — the setup-tools
# action installs pinned versions of all but jq.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
APPS="$ROOT/apps"
OUT="${OUT:-$ROOT/.out}"
# What the cluster runs; charts are rendered and validated against it.
KUBE_VERSION="${KUBE_VERSION:-1.35.0}"
# The only architecture in the cluster. Scanned and stored per tag.
PLATFORM="${PLATFORM:-linux/amd64}"
# Severity that fails the gate. Only vulnerabilities with a fix available
# count — nothing can be done about the rest except accepting them.
FAIL_ON="${FAIL_ON:-CRITICAL}"
# The publish job gets these from the runner's .env (see homelab-cluster's
# github_runner role).
ZOT_REGISTRY="${ZOT_REGISTRY:-localhost:5000}"
CHARTS_PATH=charts
# Scanned images go under their own prefix. The pull-through cache owns
# <registry>/..., and any lookup there of a tag it lacks makes Zot fetch it
# from upstream into that same tag — so the two must never share paths. The
# nodes try scanned/<registry>/ first, then the cache, then the upstream.
SCANNED_PATH=scanned

log() { echo "==> $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

# Appends a line to the job summary on GitHub; a no-op locally.
summary() {
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    echo "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

app_file() { echo "$APPS/$1/values.yaml"; }

# app_get <app> <yq path> — empty string when unset.
app_get() { yq -r "$2 // \"\"" "$(app_file "$1")"; }

app_enabled() { [[ $(yq -r '.enabled // false' "$(app_file "$1")") == true ]]; }

enabled_apps() {
  local f app
  for f in "$APPS"/*/values.yaml; do
    app=$(basename "$(dirname "$f")")
    if app_enabled "$app"; then
      echo "$app"
    fi
  done
}

# Expands a reference the way containerd does, so it names the same path the
# nodes request through the Zot mirror:
#   nginx:1.30           -> docker.io/library/nginx:1.30
#   grafana/grafana:12   -> docker.io/grafana/grafana:12
#   quay.io/x/y          -> quay.io/x/y:latest
normalize_image() {
  local ref=$1 registry rest first
  first=${ref%%/*}
  if [[ $ref == */* && ($first == *.* || $first == *:* || $first == localhost) ]]; then
    registry=$first
    rest=${ref#*/}
  else
    registry=docker.io
    rest=$ref
  fi
  if [[ $registry == index.docker.io || $registry == registry-1.docker.io ]]; then
    registry=docker.io
  fi
  if [[ $registry == docker.io && ${rest%%[:@]*} != */* ]]; then
    rest="library/$rest"
  fi
  local last=${rest##*/}
  if [[ $last != *:* && $last != *@* ]]; then
    rest="$rest:latest"
  fi
  echo "$registry/$rest"
}

# Repository part of a normalized reference (no tag, no digest).
image_repo() {
  local ref=${1%%@*}
  local last=${ref##*/}
  if [[ $last == *:* ]]; then
    ref=${ref%:*}
  fi
  echo "$ref"
}

# Pulls or packages the app's chart, then renders it with the app's values plus
# its raw manifests into $OUT/<app>/rendered.yaml. The chart archive is left at
# $OUT/<app>/chart.tgz for publishing.
render_app() {
  local app=$1 dir="$OUT/$1"
  local ns chart_path chart_name chart_version chart_repo
  ns=$(app_get "$app" .namespace)
  chart_path=$(app_get "$app" .chart.path)
  chart_name=$(app_get "$app" .chart.name)
  chart_version=$(app_get "$app" .chart.version)
  chart_repo=$(app_get "$app" .chart.repository)
  [[ -n $ns ]] || die "$app: namespace is not set"

  rm -rf "$dir"
  mkdir -p "$dir/pull"
  yq '.values // {}' "$(app_file "$app")" > "$dir/values.yaml"

  if [[ -n $chart_path ]]; then
    log "$app: linting and packaging $chart_path"
    helm lint "$APPS/$app/$chart_path" --values "$dir/values.yaml" --quiet
    helm package "$APPS/$app/$chart_path" --destination "$dir/pull" >/dev/null
  elif [[ -n $chart_name ]]; then
    [[ -n $chart_repo && -n $chart_version ]] || die "$app: chart needs repository and version"
    log "$app: pulling $chart_name $chart_version from $chart_repo"
    if [[ $chart_repo == oci://* ]]; then
      helm pull "$chart_repo/$chart_name" --version "$chart_version" --destination "$dir/pull"
    else
      helm pull "$chart_name" --repo "$chart_repo" --version "$chart_version" --destination "$dir/pull"
    fi
  fi

  : > "$dir/rendered.yaml"
  local tgz
  tgz=$(find "$dir/pull" -name '*.tgz' -print -quit)
  if [[ -n $tgz ]]; then
    mv "$tgz" "$dir/chart.tgz"
    # Same as ArgoCD: release named after the app, test hooks skipped.
    helm template "$app" "$dir/chart.tgz" \
      --namespace "$ns" \
      --values "$dir/values.yaml" \
      --kube-version "$KUBE_VERSION" \
      --include-crds \
      --skip-tests > "$dir/rendered.yaml"
  fi

  local m
  for m in "$APPS/$app"/manifests/*.yaml; do
    [[ -e $m ]] || continue
    { echo "---"; cat "$m"; } >> "$dir/rendered.yaml"
  done
  [[ -s $dir/rendered.yaml ]] || die "$app: rendered nothing — no chart and no manifests/"
}

# Schema-checks everything the app would apply. CRDs come from the community
# catalog; kinds with no published schema are reported as skipped.
validate_app() {
  local app=$1
  log "$app: validating against Kubernetes $KUBE_VERSION schemas"
  mkdir -p "$OUT/.kubeconform-cache"
  kubeconform \
    -strict \
    -summary \
    -kubernetes-version "$KUBE_VERSION" \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -ignore-missing-schemas \
    -cache "$OUT/.kubeconform-cache" \
    "$OUT/$app/rendered.yaml"
}

# Every image the rendered manifests run, normalized, one per line.
list_images() {
  local app=$1 img
  yq -N '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str" and . != "")' \
    "$OUT/$app/rendered.yaml" | sort -u | while read -r img; do
    normalize_image "$img"
  done | sort -u > "$OUT/$app/images.txt"
  cat "$OUT/$app/images.txt"
}

# The digest that will actually run on the nodes: for a multi-arch image, the
# $PLATFORM manifest. Scanning and copying by this digest means what was
# scanned is exactly what is stored, even if the upstream tag moves meanwhile.
platform_digest() {
  crane digest --platform "$PLATFORM" "$1"
}

# Scans every image of the app. Writes a table to the job summary and fails if
# any image has a fixable vulnerability at $FAIL_ON. Accepted risks go in
# .trivyignore.yaml at the repo root, each with a statement saying why.
scan_app() {
  local app=$1 img digest json crit high failed=0
  local ignore=()
  if [[ -f $ROOT/.trivyignore.yaml ]]; then
    ignore=(--ignorefile "$ROOT/.trivyignore.yaml")
  fi
  summary "### $app"
  summary ""
  summary "| Image | Critical | High |"
  summary "|---|---:|---:|"
  : > "$OUT/$app/digests.txt"
  while read -r img; do
    [[ -n $img ]] || continue
    digest=$(platform_digest "$img")
    echo "$img $digest" >> "$OUT/$app/digests.txt"
    json="$OUT/$app/trivy-$(echo "$img" | tr '/:@' '___').json"
    log "$app: scanning $img ($digest)"
    trivy image \
      --quiet \
      --image-src remote \
      --scanners vuln \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      "${ignore[@]}" \
      --format json \
      --output "$json" \
      "$(image_repo "$img")@$digest"
    crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$json")
    high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$json")
    summary "| \`$img\` | $crit | $high |"
    local count=$crit
    if [[ $FAIL_ON == HIGH ]]; then
      count=$((crit + high))
    fi
    if (( count > 0 )); then
      failed=1
      echo "::error title=$app::$img has $count fixable $FAIL_ON+ vulnerabilities"
      jq -r --arg sev "$FAIL_ON" '
        .Results[]?.Vulnerabilities[]?
        | select(.Severity == "CRITICAL" or ($sev == "HIGH" and .Severity == "HIGH"))
        | "    \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' "$json" | sort -u >&2
    fi
  done < "$OUT/$app/images.txt"
  summary ""
  return "$failed"
}

zot_login() {
  : "${ZOT_USER:?ZOT_USER is not set — is this the self-hosted runner?}"
  : "${ZOT_PASSWORD_FILE:?ZOT_PASSWORD_FILE is not set — is this the self-hosted runner?}"
  helm registry login "$ZOT_REGISTRY" --plain-http --username "$ZOT_USER" --password-stdin < "$ZOT_PASSWORD_FILE" >/dev/null
  crane auth login "$ZOT_REGISTRY" --username "$ZOT_USER" --password-stdin < "$ZOT_PASSWORD_FILE" >/dev/null 2>&1
}

# Copies each scanned image to scanned/<registry>/<repo> in Zot, where a node
# pulling the upstream name looks first. Skips images already there at the
# same digest.
push_images() {
  local app=$1 img digest dst current
  while read -r img digest; do
    [[ -n $img ]] || continue
    if [[ $img == *@* ]]; then
      # Pinned by digest in the chart: copy what it names (the whole index if
      # it is one), so the node's pull by that digest finds it.
      dst="$ZOT_REGISTRY/$SCANNED_PATH/$(image_repo "$img")@${img##*@}"
      if crane manifest --insecure "$dst" >/dev/null 2>&1; then
        log "$app: $img already in Zot"
        continue
      fi
      log "$app: copying $img"
      crane copy --insecure "$img" "$dst"
    else
      dst="$ZOT_REGISTRY/$SCANNED_PATH/$img"
      current=$(crane digest --insecure "$dst" 2>/dev/null || true)
      if [[ $current == "$digest" ]]; then
        log "$app: $img already in Zot"
        continue
      fi
      log "$app: copying $img ($digest)"
      crane copy --insecure "$(image_repo "$img")@$digest" "$dst"
    fi
  done < "$OUT/$app/digests.txt"
}

# Pushes the chart to Zot. A version already there is left alone: upstream
# versions are immutable, and check-repo.sh makes local charts bump theirs.
push_chart() {
  local app=$1 tgz="$OUT/$1/chart.tgz" name version
  [[ -f $tgz ]] || return 0
  name=$(helm show chart "$tgz" | yq -r .name)
  version=$(helm show chart "$tgz" | yq -r .version)
  if crane manifest --insecure "$ZOT_REGISTRY/$CHARTS_PATH/$name:${version//+/_}" >/dev/null 2>&1; then
    log "$app: chart $name $version already in Zot"
    return 0
  fi
  log "$app: pushing chart $name $version"
  helm push "$tgz" "oci://$ZOT_REGISTRY/$CHARTS_PATH" --plain-http
}
