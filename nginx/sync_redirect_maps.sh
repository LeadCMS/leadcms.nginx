#!/bin/bash
# Re-generates redirect map wrapper confs and reloads nginx if anything changed.
# Needed after container startup only when the set of static sites changes.
# For .map file content updates, nginx -s reload alone is sufficient.

set -e

# Source build_redirect_map_conf from nginx.sh (NGINX_SH_SOURCED skips execution).
NGINX_SH_SOURCED=1
# shellcheck source=nginx.sh
source /customization/nginx.sh

changed=0

i=1
while true; do
  domain=$(eval "echo \${DOMAIN_${i}:-}")
  [ -z "$domain" ] && break

  domainTarget=$(eval "echo \${DOMAINTARGET_${i}:-}")

  if [ "${domainTarget:0:1}" = "/" ]; then
    redirectMapVarSuffix=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
    mapOutput="/etc/nginx/sites/maps/${domain}.conf"

    tmpFile=$(mktemp)
    build_redirect_map_conf "$domain" "$domainTarget" "$redirectMapVarSuffix" "$tmpFile"
    if ! diff -q "$tmpFile" "$mapOutput" >/dev/null 2>&1; then
      cp "$tmpFile" "$mapOutput"
      echo "Updated redirect map config for $domain"
      changed=1
    fi
    rm -f "$tmpFile"
  fi

  i=$((i + 1))
done

if [ "$changed" -eq 1 ]; then
  echo "Redirect maps changed, validating and reloading nginx"
  nginx -t && nginx -s reload
fi
