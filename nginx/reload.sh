#!/bin/bash
# Re-renders the configuration from config.env and hot-reloads nginx.
#
# `nginx -s reload` does not drop connections: the master re-reads the config,
# starts new workers and lets the old ones finish their in-flight requests. The
# rendered files are snapshotted first, so a configuration nginx refuses is
# rolled back on disk and the running nginx — which only ever loaded the
# previous, valid config — keeps serving traffic untouched.

set -e

# shellcheck source=lib.sh
. /customization/lib.sh

# Checked before anything else: a hot reload exists to apply an edit to
# config.env, so without the file there is nothing to apply. Rendering the
# environment baked in at container creation would reload nginx, print a clean
# summary and exit 0 while changing nothing — the edit lost in silence.
require_config_file

backupDir=$(mktemp -d)
trap 'rm -rf "$backupDir"' EXIT

snapshot_sites "$SITES_DIR" "$backupDir/sites"
cp -a "$MAIN_CONF" "$backupDir/nginx.conf" 2>/dev/null || true

restore_backup() {
  echo "Restoring the previous configuration"
  rm -f "$SITES_DIR"/*.conf "$SITES_DIR"/maps/*.conf
  cp -a "$backupDir/sites"/*.conf "$SITES_DIR/" 2>/dev/null || true
  cp -a "$backupDir/sites/maps"/*.conf "$SITES_DIR/maps/" 2>/dev/null || true
  if [ -f "$backupDir/nginx.conf" ]; then
    cp -a "$backupDir/nginx.conf" "$MAIN_CONF"
  fi
  return 0
}

if ! /customization/render.sh; then
  echo "Failed to render the configuration from ${CONFIG_FILE}" >&2
  restore_backup
  exit 1
fi

echo "Configuration changes:"
summarize_changes "$backupDir/sites" "$SITES_DIR" "$backupDir/nginx.conf" "$MAIN_CONF"

if ! nginx -t; then
  echo "Nginx rejected the rendered configuration; rolling back and keeping the running config" >&2
  restore_backup
  exit 1
fi

if [ -s /var/run/nginx.pid ]; then
  echo "Reloading Nginx configuration"
  nginx -s reload
else
  echo "Nginx is not running; configuration rendered without a reload"
fi
