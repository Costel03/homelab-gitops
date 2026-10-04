#!/usr/bin/env bash
# Installs pinned CLI tools into the runner tool cache and puts them on PATH.
# Bump a version here together with its sha256 (from the release's checksum
# file) — a mismatch fails the job instead of running an unverified binary.
set -euo pipefail

HELM_VERSION=v4.3.0
HELM_SHA256=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb
YQ_VERSION=v4.54.1
YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
CRANE_VERSION=v0.22.1
CRANE_SHA256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
TRIVY_VERSION=v0.75.0
TRIVY_SHA256=c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f
ACTIONLINT_VERSION=v1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

CACHE="${RUNNER_TOOL_CACHE:-$HOME/.cache}/homelab-tools"
BIN="$CACHE/bin"
mkdir -p "$BIN"

# fetch <name> <version> <url> <sha256> <path-inside-archive or "-" for a bare binary>
fetch() {
  local name=$1 version=$2 url=$3 sha=$4 member=$5
  local stamp="$CACHE/.$name-$version"
  if [[ -f $stamp && -x $BIN/$name ]]; then
    return
  fi
  local tmp
  tmp=$(mktemp -d)
  curl --fail --silent --show-error --location --retry 3 --output "$tmp/download" "$url"
  echo "$sha  $tmp/download" | sha256sum --check --quiet
  if [[ $member == - ]]; then
    install -m 0755 "$tmp/download" "$BIN/$name"
  else
    tar --extract --gzip --file "$tmp/download" --directory "$tmp" "$member"
    install -m 0755 "$tmp/$member" "$BIN/$name"
  fi
  rm -rf "$tmp"
  rm -f "$CACHE/.$name-"*
  touch "$stamp"
  echo "installed $name $version" >&2
}

fetch helm "$HELM_VERSION" \
  "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" linux-amd64/helm
fetch yq "$YQ_VERSION" \
  "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64" "$YQ_SHA256" -
fetch crane "$CRANE_VERSION" \
  "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz" "$CRANE_SHA256" crane
fetch kubeconform "$KUBECONFORM_VERSION" \
  "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" "$KUBECONFORM_SHA256" kubeconform
fetch trivy "$TRIVY_VERSION" \
  "https://github.com/aquasecurity/trivy/releases/download/$TRIVY_VERSION/trivy_${TRIVY_VERSION#v}_Linux-64bit.tar.gz" "$TRIVY_SHA256" trivy
fetch actionlint "$ACTIONLINT_VERSION" \
  "https://github.com/rhysd/actionlint/releases/download/$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION#v}_linux_amd64.tar.gz" "$ACTIONLINT_SHA256" actionlint

if [[ -n ${GITHUB_PATH:-} ]]; then
  echo "$BIN" >> "$GITHUB_PATH"
else
  echo "$BIN"
fi
