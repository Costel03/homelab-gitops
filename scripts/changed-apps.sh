#!/usr/bin/env bash
# Prints a JSON array of the enabled apps that changed between <base> and HEAD,
# for a workflow matrix. Every enabled app if <base> does not exist yet (the
# first publish) or if the pipeline itself changed.
#
#   scripts/changed-apps.sh origin/main       a PR, against its base
#   scripts/changed-apps.sh origin/deployed   publish: everything not yet deployed
#   scripts/changed-apps.sh all
set -euo pipefail
source "$(dirname "$0")/lib.sh"

base=${1:?usage: changed-apps.sh <base-ref>|all}

to_json() { jq --raw-input --slurp --compact-output 'split("\n") | map(select(. != "")) | unique'; }

if [[ $base == all ]] || ! git rev-parse --quiet --verify "$base^{commit}" >/dev/null; then
  enabled_apps | to_json
  exit 0
fi

changed=$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD)

if grep -qE '^(scripts/|\.github/|\.trivyignore\.yaml$)' <<<"$changed"; then
  enabled_apps | to_json
  exit 0
fi

{
  grep -oE '^apps/[^/]+/' <<<"$changed" | cut -d/ -f2 | sort -u | while read -r app; do
    if [[ -f $(app_file "$app") ]] && app_enabled "$app"; then
      echo "$app"
    fi
  done
} | to_json
