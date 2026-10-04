#!/usr/bin/env bash
# Runs the pipeline for one app.
#
#   scripts/app.sh check   <app>   render, validate, scan            (PRs)
#   scripts/app.sh publish <app>   the same, then push to Zot        (main)
#
# Output lands in .out/<app>/.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

mode=${1:?usage: app.sh check|publish <app>}
app=${2:?usage: app.sh check|publish <app>}
[[ -f $(app_file "$app") ]] || die "no such app: $app"

render_app "$app"
validate_app "$app"

log "$app: images"
list_images "$app" | sed 's/^/    /' >&2

scan_app "$app" || die "$app: scan gate failed — bump the version, or accept the finding in .trivyignore.yaml with a statement"

case $mode in
  check) ;;
  publish)
    zot_login
    push_images "$app"
    push_chart "$app"
    ;;
  *) die "unknown mode: $mode" ;;
esac
log "$app: done"
