#!/bin/bash
# Shared rendering helpers for the nginx container.
#
# Sourced by nginx.sh (entrypoint), render.sh and reload.sh. This file must not
# execute anything on its own so that rendering is a plain function call that
# can run at container start *and* against an already running nginx.

CONFIG_FILE="${NGINX_CONFIG_FILE:-/etc/nginx/hostconfig/config.env}"
CUSTOMIZATION_DIR="${CUSTOMIZATION_DIR:-/customization}"
SITES_DIR="${SITES_DIR:-/etc/nginx/sites}"
MAIN_CONF="${MAIN_CONF:-/etc/nginx/nginx.conf}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
DUMMY_CERT_DIR="$SITES_DIR/ssl/dummy"
DHPARAM_FILE="$SITES_DIR/ssl/ssl-dhparams.pem"

# Fails with the remediation when the bind-mounted config.env is missing.
#
# Kept separate from load_config so a caller can refuse *before* doing any work
# — reload.sh snapshots the rendered configuration before it renders — and
# without load_config's side effect of clearing and re-sourcing the environment.
require_config_file() {
  [ -f "$CONFIG_FILE" ] && return 0

  cat >&2 <<EOF
Error: $CONFIG_FILE not found, so this render would fall back to the
environment captured when the container was created and silently drop your
config.env edits. Nothing was changed.

Add the project directory to the nginx service's volumes in docker-compose.yml:

      - ./:/etc/nginx/hostconfig:ro

then recreate the stack once with: docker compose up -d --build
EOF
  return 1
}

# Loads config.env from the bind mount so a *running* container can see edits
# made on the host. Compose only reads env_file at container creation, so
# without this a config change would need a recreate.
#
# The mount is the *directory* holding config.env, never the file itself: an
# editor that writes a temp file and renames it over the original (vim, VS
# Code, sed -i) replaces the inode, and a file bind mount would still point at
# the deleted one — the container would lose config.env on the first edit.
#
# The baked-in copy is cleared first: a domain deleted from config.env would
# otherwise still be present in the process environment and would never be
# pruned from the rendered configuration.
#
# A missing config.env is fatal by default. Only the container entrypoint
# passes --allow-stale, because at creation time Compose's env_file copy is by
# definition current. Every later render exists to apply an edit to config.env,
# and rendering from the baked-in environment would report success while
# changing nothing at all — the one failure mode an operator cannot see.
load_config() {
  local allowStale=0
  case "${1:-}" in
    --allow-stale) allowStale=1 ;;
    "") ;;
    *) echo "load_config: unknown option '$1'" >&2; return 2 ;;
  esac

  if [ ! -f "$CONFIG_FILE" ]; then
    if [ "$allowStale" != "1" ]; then
      require_config_file
      return 1
    fi

    # Startup with the baked-in environment still works; it just cannot pick up
    # later edits. Warned once per process tree so the entrypoint's own call and
    # the render.sh it spawns do not print the same paragraph twice.
    if [ -z "${NGINX_CONFIG_STALE_WARNED:-}" ]; then
      export NGINX_CONFIG_STALE_WARNED=1
      echo "Warning: $CONFIG_FILE not found; falling back to the environment captured when the container was created. Hot reload will not see config.env edits until docker-compose.yml mounts the project directory at /etc/nginx/hostconfig and the stack is recreated." >&2
    fi
    return 0
  fi

  local name
  for name in $(compgen -v); do
    case "$name" in
      NGINX_VERSION|NJS_VERSION|NJS_RELEASE|PKG_RELEASE|DYNPKG_RELEASE) ;;
      DOMAIN_*|DOMAINTARGET_*|DOMAINTARGETINDEX_*|DOMAINSSE_*|DOMAINWSS_*) unset "$name" ;;
      STATICSITETYPE_*|CERTBOTEMAIL_*|CERTBOT_*|NGINX_*) unset "$name" ;;
    esac
  done

  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a
}

cpu_count() {
  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  else
    grep -c '^processor' /proc/cpuinfo
  fi
}

max_upload_size() {
  if [ -z "${NGINX_UPLOADSIZE_MAX:-}" ]; then
    echo "1M"
  else
    echo "$NGINX_UPLOADSIZE_MAX"
  fi
}

# Lists the domain indexes configured in config.env, in order.
config_domain_indexes() {
  local i=1
  while [ -n "$(eval "echo \${DOMAIN_$i:-}")" ]; do
    echo "$i"
    i=$((i + 1))
  done
}

# Directory holding the certificate nginx should serve for a domain: the real
# Let's Encrypt one when it exists, the self-signed placeholder otherwise.
# Choosing at render time keeps rendering idempotent — the previous code
# rendered the dummy path and then sed-patched the file in place.
cert_dir_for() {
  local domain=$1
  if [ -d "$LETSENCRYPT_DIR/live/$domain" ]; then
    printf '%s/live/%s' "$LETSENCRYPT_DIR" "$domain"
  else
    printf '%s/%s' "$DUMMY_CERT_DIR" "$domain"
  fi
}

ensure_dhparam() {
  [ -f "$DHPARAM_FILE" ] && return 0
  mkdir -p "$SITES_DIR/ssl"
  openssl dhparam -out "$DHPARAM_FILE" 2048
}

ensure_dummy_certificate() {
  local domain=$1 confFile
  [ -f "$DUMMY_CERT_DIR/$domain/fullchain.pem" ] && return 0

  echo "Generating dummy ceritificate for $domain"
  mkdir -p "$DUMMY_CERT_DIR/$domain"
  confFile=$(mktemp)
  printf "[dn]\nCN=%s\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:%s" "$domain" "$domain" > "$confFile"
  openssl req -x509 -out "$DUMMY_CERT_DIR/$domain/fullchain.pem" -keyout "$DUMMY_CERT_DIR/$domain/privkey.pem" \
    -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=${domain}" -extensions EXT -config "$confFile"
  rm -f "$confFile"
}

# Builds an nginx map conf file that includes the plain redirect files directly.
# The include uses glob patterns so nginx silently skips missing files.
# When redirects/ or .map files appear later, nginx -s reload is sufficient.
# Always returns 0 — a wrapper conf is written for every static site so that
# the if-blocks in the server config are always present and ready.
build_redirect_map_conf() {
  local domain=$1 domainTarget=$2 varSuffix=$3 outputFile=$4
  local mapDir="${domainTarget}/redirects"

  echo "Generating redirect map config for $domain"
  {
    printf 'map $request_uri $redirect_301_%s {\n' "$varSuffix"
    printf '    default "";\n'
    printf '    include %s/30[1].map;\n' "$mapDir"
    printf '}\n\n'
    printf 'map $request_uri $redirect_302_%s {\n' "$varSuffix"
    printf '    default "";\n'
    printf '    include %s/30[2].map;\n' "$mapDir"
    printf '}\n\n'
    printf 'map $redirect_301_%s $redirect_301_%s_url {\n' "$varSuffix" "$varSuffix"
    printf '    ~^https?:// $redirect_301_%s;\n' "$varSuffix"
    printf '    default      $scheme://$http_host$redirect_301_%s;\n' "$varSuffix"
    printf '}\n\n'
    printf 'map $redirect_302_%s $redirect_302_%s_url {\n' "$varSuffix" "$varSuffix"
    printf '    ~^https?:// $redirect_302_%s;\n' "$varSuffix"
    printf '    default      $scheme://$http_host$redirect_302_%s;\n' "$varSuffix"
    printf '}\n'
  } > "$outputFile"
  return 0
}

render_main_nginx_config() {
  local outputFile=${1:-$MAIN_CONF}
  local cpuCount workerProcesses workerConnections workerRlimitNofile
  local multiAccept keepaliveTimeout keepaliveRequests
  local accessLogBuffer accessLogFlush accessLogDirective
  local openFileCacheEnabled openFileCacheMax openFileCacheInactive openFileCacheValid openFileCacheMinUses
  local openFileCacheBlock
  local templateFile

  cpuCount=$(cpu_count)
  workerProcesses=${NGINX_WORKER_PROCESSES:-$cpuCount}
  workerConnections=${NGINX_WORKER_CONNECTIONS:-1024}
  workerRlimitNofile=${NGINX_WORKER_RLIMIT_NOFILE:-$((workerProcesses * workerConnections * 2))}
  multiAccept=${NGINX_MULTI_ACCEPT:-off}
  keepaliveTimeout=${NGINX_KEEPALIVE_TIMEOUT:-65}
  keepaliveRequests=${NGINX_KEEPALIVE_REQUESTS:-1000}
  accessLogBuffer=${NGINX_ACCESS_LOG_BUFFER:-}
  accessLogFlush=${NGINX_ACCESS_LOG_FLUSH:-}
  if [ -n "$accessLogBuffer" ] || [ -n "$accessLogFlush" ]; then
    accessLogDirective="access_log /var/log/nginx/access.log main"
    [ -n "$accessLogBuffer" ] && accessLogDirective="$accessLogDirective buffer=$accessLogBuffer"
    [ -n "$accessLogFlush" ] && accessLogDirective="$accessLogDirective flush=$accessLogFlush"
    accessLogDirective="$accessLogDirective;"
  else
    accessLogDirective="access_log /var/log/nginx/access.log main;"
  fi

  openFileCacheEnabled=${NGINX_OPEN_FILE_CACHE_ENABLED:-0}
  if [ "$openFileCacheEnabled" = "1" ]; then
    openFileCacheMax=${NGINX_OPEN_FILE_CACHE_MAX:-$((workerProcesses * workerConnections))}
    openFileCacheInactive=${NGINX_OPEN_FILE_CACHE_INACTIVE:-30s}
    openFileCacheValid=${NGINX_OPEN_FILE_CACHE_VALID:-60s}
    openFileCacheMinUses=${NGINX_OPEN_FILE_CACHE_MIN_USES:-2}
    openFileCacheBlock="open_file_cache max=$openFileCacheMax inactive=$openFileCacheInactive;
    open_file_cache_valid $openFileCacheValid;
    open_file_cache_min_uses $openFileCacheMinUses;
    open_file_cache_errors off;"
  else
    openFileCacheBlock="open_file_cache off;"
  fi

  echo "Rendering main Nginx configuration for $workerProcesses workers and $workerConnections worker connections"

  templateFile=$(cat "$CUSTOMIZATION_DIR/nginx.conf.tpl")
  templateFile=$(echo "${templateFile//\$\{workerProcesses\}/$workerProcesses}")
  templateFile=$(echo "${templateFile//\$\{workerConnections\}/$workerConnections}")
  templateFile=$(echo "${templateFile//\$\{workerRlimitNofile\}/$workerRlimitNofile}")
  templateFile=$(echo "${templateFile//\$\{multiAccept\}/$multiAccept}")
  templateFile=$(echo "${templateFile//\$\{keepaliveTimeout\}/$keepaliveTimeout}")
  templateFile=$(echo "${templateFile//\$\{keepaliveRequests\}/$keepaliveRequests}")
  templateFile=$(echo "${templateFile//\$\{accessLogDirective\}/$accessLogDirective}")
  templateFile=$(echo "${templateFile//\$\{openFileCacheBlock\}/$openFileCacheBlock}")
  echo "$templateFile" > "$outputFile"
}

# Renders one domain (config.env index $1) into $2, plus its redirect map conf.
# Sets RENDERED_DOMAIN to the domain that was rendered, or empty when the index
# is not configured / is misconfigured.
render_site() {
  local i=$1 outSitesDir=$2
  local domain domainTarget domainTargetIndex maxUploadSize
  local vHostTemplate proxyResolverTemplate sseLocationTemplate wssLocationTemplate redirectsBlock
  local staticSiteType redirectMapVarSuffix mapOutput
  local sseVar sseEndpoints ssePath sseLocationBlock
  local wssVar wssEndpoints wssPath wssLocationBlock
  local vHostLocationTemplate i_location domainLocation domainLocationTarget vHostLocation
  local locationAuthBlock locationAuthEnabled locationAuthRealm locationAuthFile
  local authBlock domainAuthEnabled domainAuthRealm domainAuthFile
  local templateFile sslCertDir

  RENDERED_DOMAIN=""

  domain=$(eval "echo \${DOMAIN_$i:-}")
  [ -z "$domain" ] && return 1

  domainTarget=$(eval "echo \${DOMAINTARGET_$i:-}")
  if [ -z "$domainTarget" ]; then
    echo "Error: Failed to construct nginx configuration files. DOMAINTARGET_$i not found"
    return 1
  fi

  domainTargetIndex=$(eval "echo \${DOMAINTARGETINDEX_$i:-}")
  [ -z "$domainTargetIndex" ] && domainTargetIndex="index.html"

  maxUploadSize=$(max_upload_size)

  vHostTemplate=""
  proxyResolverTemplate=""
  sseLocationTemplate=""
  wssLocationTemplate=""
  redirectsBlock=""
  if [ "${domainTarget:0:1}" = "/" ]; then
    # Check for static site type
    staticSiteType=$(eval "echo \${STATICSITETYPE_$i:-}")
    if [[ "$staticSiteType" == "Gatsby" ]]; then
      vHostTemplate=$(cat "$CUSTOMIZATION_DIR/vhost_static_gatsby.tpl")
    elif [[ "$staticSiteType" == "NextJS" ]]; then
      vHostTemplate=$(cat "$CUSTOMIZATION_DIR/vhost_static_nextjs.tpl")
    else
      vHostTemplate=$(cat "$CUSTOMIZATION_DIR/vhost_static.tpl")
    fi
    # Always generate redirect map conf and if-blocks for static sites.
    # Glob includes are silent no-ops when files don't exist yet;
    # nginx -s reload is all that's needed when .map files appear later.
    redirectMapVarSuffix=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
    mapOutput="${outSitesDir}/maps/${domain}.conf"
    build_redirect_map_conf "$domain" "$domainTarget" "$redirectMapVarSuffix" "$mapOutput"
    redirectsBlock="    if (\$redirect_301_${redirectMapVarSuffix}) { return 301 \$redirect_301_${redirectMapVarSuffix}_url; }
    if (\$redirect_302_${redirectMapVarSuffix}) { return 302 \$redirect_302_${redirectMapVarSuffix}_url; }"
  elif [ "${domainTarget:0:1}" = ">" ]; then
    vHostTemplate=$(cat "$CUSTOMIZATION_DIR/vhost_redirect.tpl")  # begins with '>' -> temporary redirect (HTTP 302)
    domainTarget="${domainTarget:1}"                                    # remove '>' character
  else
    vHostTemplate=$(cat "$CUSTOMIZATION_DIR/vhost_service.tpl") # else - serve service
    proxyResolverTemplate='    resolver 127.0.0.11 valid=300s ipv6=off;
    resolver_timeout 10s;'
    # --- SSE support ---
    sseVar="DOMAINSSE_$i"
    sseEndpoints=$(eval "echo \${$sseVar:-}")
    if [ -n "$sseEndpoints" ]; then
      for ssePath in $sseEndpoints; do
        sseLocationBlock=$(cat "$CUSTOMIZATION_DIR/vhost_location_sse.tpl")
        sseLocationBlock=$(echo "$sseLocationBlock" | sed "s|\${ssePath}|$ssePath|g" | sed "s|\${target}|$domainTarget|g")
        sseLocationTemplate="${sseLocationTemplate}
${sseLocationBlock}
"
      done
    fi
    # --- WSS support ---
    wssVar="DOMAINWSS_$i"
    wssEndpoints=$(eval "echo \${$wssVar:-}")
    if [ -n "$wssEndpoints" ]; then
      for wssPath in $wssEndpoints; do
        wssLocationBlock=$(cat "$CUSTOMIZATION_DIR/vhost_location_wss.tpl")
        wssLocationBlock=$(echo "$wssLocationBlock" | sed "s|\${wssPath}|$wssPath|g" | sed "s|\${target}|$domainTarget|g" | sed "s|\${maxUploadSize}|$maxUploadSize|g")
        wssLocationTemplate="${wssLocationTemplate}
${wssLocationBlock}
"
      done
    fi
    vHostTemplate=$(echo "${vHostTemplate//\${sseLocationTemplatePlaceholder\}/$sseLocationTemplate}")
    vHostTemplate=$(echo "${vHostTemplate//\${wssLocationTemplatePlaceholder\}/$wssLocationTemplate}")
  fi

  local IFS=' '
  vHostTemplate=$(echo "${vHostTemplate//\$\{target\}/"$domainTarget"}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{index\}/"$domainTargetIndex"}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{maxUploadSize\}/"$maxUploadSize"}")
  vHostLocationTemplate=""

  i_location=1
  while true
  do
    # Need to set DOMAIN_[...]_LOCATION_[...] , DOMAIN_[...]_LOCATION_[...]_TARGET
    # loop unit reach end of DOMAIN_[...]_LOCATION_[1,2,3,4]
    domainLocation=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}:-}")
    [ -z "$domainLocation" ] && break

    domainLocationTarget=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_TARGET:-}")
    if [ -z "$domainLocationTarget" ]; then
      echo "Error: Failed to construct nginx configuration files. DOMAIN_${i}_LOCATION_${i_location}_TARGET not found"
      break
    fi

    domainTargetIndex=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_INDEX:-}")
    [ -z "$domainTargetIndex" ] && domainTargetIndex="index.html"

    if [ "${domainLocationTarget:0:1}" = "/" ]; then
      vHostLocation=$(cat "$CUSTOMIZATION_DIR/vhost_location_static.tpl")  # begins with '/' -> path -> serve static files
    else
      vHostLocation=$(cat "$CUSTOMIZATION_DIR/vhost_location.tpl") # else - serve service
      proxyResolverTemplate='    resolver 127.0.0.11 valid=300s ipv6=off;
    resolver_timeout 10s;'
    fi
    vHostLocation=$(echo "${vHostLocation//\$\{location\}/"$domainLocation"}")
    vHostLocation=$(echo "${vHostLocation//\$\{locationTarget\}/"$domainLocationTarget"}")
    vHostLocation=$(echo "${vHostLocation//\$\{maxUploadSize\}/"$maxUploadSize"}")
    vHostLocation=$(echo "${vHostLocation//\$\{index\}/"$domainTargetIndex"}")
    locationAuthBlock=""
    locationAuthEnabled=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_AUTH:-}")
    if [ -n "$locationAuthEnabled" ] && [ "$locationAuthEnabled" != "0" ]; then
      locationAuthRealm=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_AUTH_REALM:-}")
      [ -z "$locationAuthRealm" ] && locationAuthRealm="Restricted Area"
      locationAuthFile=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_AUTH_FILE:-}")
      [ -z "$locationAuthFile" ] && locationAuthFile="$domain"
      locationAuthBlock="        auth_basic \"${locationAuthRealm}\";
        auth_basic_user_file /etc/nginx/htpasswd/${locationAuthFile};"
    fi
    vHostLocation=$(echo "${vHostLocation//\$\{locationAuthBlock\}/$locationAuthBlock}")
    vHostLocationTemplate="${vHostLocationTemplate} ${vHostLocation}"

    i_location=$((i_location+1))
  done
  authBlock=""
  domainAuthEnabled=$(eval "echo \${DOMAIN_${i}_AUTH:-}")
  if [ -n "$domainAuthEnabled" ] && [ "$domainAuthEnabled" != "0" ]; then
    domainAuthRealm=$(eval "echo \${DOMAIN_${i}_AUTH_REALM:-}")
    [ -z "$domainAuthRealm" ] && domainAuthRealm="Restricted Area"
    domainAuthFile=$(eval "echo \${DOMAIN_${i}_AUTH_FILE:-}")
    [ -z "$domainAuthFile" ] && domainAuthFile="$domain"
    authBlock="    auth_basic \"${domainAuthRealm}\";
    auth_basic_user_file /etc/nginx/htpasswd/${domainAuthFile};"
  fi
  vHostTemplate=$(echo "${vHostTemplate//\${proxyResolverTemplatePlaceholder\}/$proxyResolverTemplate}")
  vHostTemplate=$(echo "${vHostTemplate//\${redirectsTemplatePlaceholder\}/"$redirectsBlock"}")
  vHostTemplate=$(echo "${vHostTemplate//\${locationTemplatePlaceholder\}/"$vHostLocationTemplate"}")
  vHostTemplate=$(echo "${vHostTemplate//\${authBlock\}/$authBlock}")

  echo "Rendering Nginx configuration file ${outSitesDir}/$domain.conf"

  sslCertDir=$(cert_dir_for "$domain")

  templateFile=$(cat "$CUSTOMIZATION_DIR/site.conf.tpl")
  templateFile=$(echo "${templateFile//\$\{sslCertDir\}/"$sslCertDir"}")
  templateFile=$(echo "${templateFile//\$\{domain\}/"$domain"}")
  templateFile=$(echo "${templateFile//\$\{vhostinclude\}/"$vHostTemplate"}")
  echo "$templateFile" > "${outSitesDir}/$domain.conf"

  RENDERED_DOMAIN="$domain"
  return 0
}

# Prints a +/-/~ summary of the difference between two rendered config trees.
# Used by render.sh --dry-run (staging vs live) and by reload.sh (pre-render
# backup vs live) so both report changes the same way.
summarize_changes() {
  local oldDir=$1 newDir=$2 oldMain=$3 newMain=$4
  local added=0 removed=0 modified=0
  local f rel

  if [ -f "$oldMain" ] && [ -f "$newMain" ] && ! diff -q "$oldMain" "$newMain" >/dev/null 2>&1; then
    echo "  ~ nginx.conf"
    modified=$((modified + 1))
  fi

  for f in "$newDir"/*.conf "$newDir"/maps/*.conf; do
    [ -e "$f" ] || continue
    rel=${f#"$newDir"/}
    if [ ! -e "$oldDir/$rel" ]; then
      echo "  + $rel"
      added=$((added + 1))
    elif ! diff -q "$oldDir/$rel" "$f" >/dev/null 2>&1; then
      echo "  ~ $rel"
      modified=$((modified + 1))
    fi
  done

  for f in "$oldDir"/*.conf "$oldDir"/maps/*.conf; do
    [ -e "$f" ] || continue
    rel=${f#"$oldDir"/}
    if [ ! -e "$newDir/$rel" ]; then
      echo "  - $rel"
      removed=$((removed + 1))
    fi
  done

  echo "  ${added} added, ${removed} removed, ${modified} changed"
}

# Copies just the rendered configuration out of a sites dir (skipping ssl/, which
# holds the dhparam file and the dummy certificates and never needs snapshotting).
snapshot_sites() {
  local srcDir=$1 destDir=$2
  mkdir -p "$destDir/maps"
  cp -a "$srcDir"/*.conf "$destDir/" 2>/dev/null || true
  cp -a "$srcDir"/maps/*.conf "$destDir/maps/" 2>/dev/null || true
}
