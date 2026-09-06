#!/bin/bash
# Renders the complete nginx configuration from config.env.
#
# Idempotent and safe to re-run against a live container: every vhost, redirect
# map and the main nginx.conf are regenerated from scratch, and configuration
# for domains that were removed from config.env is pruned. It does not reload
# nginx — reload.sh does that, with validation and rollback.

set -e

# shellcheck source=lib.sh
. /customization/lib.sh

dryRun=0
allowStale=""

usage() {
  cat <<'USAGE'
Usage: render.sh [--dry-run] [--allow-stale-config]

  --dry-run              Render into a staging directory and print what would
                         change. Nothing on disk is modified.
  --allow-stale-config   Render from the environment Compose baked in at
                         container creation when config.env is not mounted,
                         instead of refusing. Only the entrypoint passes this;
                         see load_config in lib.sh for why every other caller
                         must not.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dryRun=1 ;;
    --allow-stale-config) allowStale="--allow-stale" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "render.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# After parsing, so --allow-stale-config is honoured wherever it appears.
# shellcheck disable=SC2086 # deliberately unquoted: empty means "no flag"
load_config $allowStale

if [ "$dryRun" = "1" ]; then
  stagingDir=$(mktemp -d)
  trap 'rm -rf "$stagingDir"' EXIT
  outSitesDir="$stagingDir/sites"
  outMainConf="$stagingDir/nginx.conf"
else
  outSitesDir="$SITES_DIR"
  outMainConf="$MAIN_CONF"
fi

# Drop configuration belonging to domains that are no longer in config.env.
# Without this a deleted domain would keep being served until the next recreate.
prune_stale_confs() {
  local dir=$1 keep=$2 file base
  [ -d "$dir" ] || return 0
  for file in "$dir"/*.conf; do
    [ -e "$file" ] || continue
    base=$(basename "$file" .conf)
    [ "$base" = "placeholder" ] && continue
    case " $keep " in
      *" $base "*) continue ;;
    esac
    echo "Removing stale configuration $file"
    rm -f "$file"
  done
}

render_all() {
  local i renderedDomains=""

  mkdir -p "$outSitesDir/maps"
  # Placeholder keeps the `include .../maps/*.conf` glob from failing when no
  # static site is configured.
  echo "# Redirect map includes placeholder" > "$outSitesDir/maps/placeholder.conf"

  render_main_nginx_config "$outMainConf"

  for i in $(config_domain_indexes); do
    if render_site "$i" "$outSitesDir"; then
      renderedDomains="$renderedDomains $RENDERED_DOMAIN"
      if [ "$dryRun" != "1" ]; then
        ensure_dummy_certificate "$RENDERED_DOMAIN"
      fi
    fi
  done

  prune_stale_confs "$outSitesDir" "$renderedDomains"
  prune_stale_confs "$outSitesDir/maps" "$renderedDomains"
}

if [ "$dryRun" = "1" ]; then
  # Per-file progress would only name throwaway staging paths; errors still show.
  render_all >/dev/null
  echo "Dry run — nothing was applied. Pending changes:"
  summarize_changes "$SITES_DIR" "$outSitesDir" "$MAIN_CONF" "$outMainConf"
else
  render_all
fi
