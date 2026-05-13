#!/bin/bash

set -e

cpu_count() {
  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  else
    grep -c '^processor' /proc/cpuinfo
  fi
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

  templateFile=$(cat /customization/nginx.conf.tpl)
  templateFile=$(echo "${templateFile//\$\{workerProcesses\}/$workerProcesses}")
  templateFile=$(echo "${templateFile//\$\{workerConnections\}/$workerConnections}")
  templateFile=$(echo "${templateFile//\$\{workerRlimitNofile\}/$workerRlimitNofile}")
  templateFile=$(echo "${templateFile//\$\{multiAccept\}/$multiAccept}")
  templateFile=$(echo "${templateFile//\$\{keepaliveTimeout\}/$keepaliveTimeout}")
  templateFile=$(echo "${templateFile//\$\{keepaliveRequests\}/$keepaliveRequests}")
  templateFile=$(echo "${templateFile//\$\{accessLogDirective\}/$accessLogDirective}")
  templateFile=$(echo "${templateFile//\$\{openFileCacheBlock\}/$openFileCacheBlock}")
  echo "$templateFile" > /etc/nginx/nginx.conf
}

use_dummy_certificate() {
  if grep -q "/etc/letsencrypt/live/$1" "/etc/nginx/sites/$1.conf"; then
    echo "Switching Nginx to use dummy certificate for $1"
    sed -i "s|/etc/letsencrypt/live/$1|/etc/nginx/sites/ssl/dummy/$1|g" "/etc/nginx/sites/$1.conf"
  fi
}

use_lets_encrypt_certificate() {
  if grep -q "/etc/nginx/sites/ssl/dummy/$1" "/etc/nginx/sites/$1.conf"; then
    echo "Switching Nginx to use Let's Encrypt certificate for $1"
    sed -i "s|/etc/nginx/sites/ssl/dummy/$1|/etc/letsencrypt/live/$1|g" "/etc/nginx/sites/$1.conf"
  fi
}

reload_nginx() {
  echo "Reloading Nginx configuration"
  nginx -s reload
}

wait_for_lets_encrypt() {
  until [ -d "/etc/letsencrypt/live/$1" ]; do
    echo "Waiting for Let's Encrypt certificates for $1"
    sleep 5s & wait ${!}
  done
  use_lets_encrypt_certificate "$1"
  reload_nginx
}

  if [[ -z $(eval "echo \${NGINX_UPLOADSIZE_MAX}") ]]; then
    maxUploadSize='1M'
    break
  else
    maxUploadSize=$(eval "echo \${NGINX_UPLOADSIZE_MAX}")
  fi

if [ ! -f /etc/nginx/sites/ssl/ssl-dhparams.pem ]; then
  mkdir -p "/etc/nginx/sites/ssl"
  openssl dhparam -out /etc/nginx/sites/ssl/ssl-dhparams.pem 2048
fi

# When sourced by sync_redirect_maps.sh we only want the functions above.
[ "${NGINX_SH_SOURCED:-0}" = "1" ] && return 0

# Ensure the maps directory exists and has a placeholder so the include glob never fails
mkdir -p /etc/nginx/sites/maps
echo "# Redirect map includes placeholder" > /etc/nginx/sites/maps/placeholder.conf

render_main_nginx_config

i=1
while true
do
  # Need to set DOMAIN_[...] , DOMAINTARGET_[...]
  # loop unit reach end of DOMAIN_[1,2,3,4]
  if [[ -z $(eval "echo \${DOMAIN_$i}") ]]; then
    break
  else
    domain=$(eval "echo \${DOMAIN_$i}")
  fi
  if [[ -z $(eval "echo \${DOMAINTARGET_$i}") ]]; then
    echo 'Error: Failed to construct nginx configuration files. DOMAINTARGET_${i} not found'
    break
  else
    domainTarget=$(eval "echo \${DOMAINTARGET_$i}")
  fi
  if [[ -z $(eval "echo \${DOMAINTARGETINDEX_$i}") ]]; then
    domainTargetIndex="index.html"
  else
    domainTarget=$(eval "echo \${DOMAINTARGET_$i}")
  fi

  vHostTemplate=""
  proxyResolverTemplate=""
  sseLocationTemplate=""
  wssLocationTemplate=""
  redirectsBlock=""
  if [ "${domainTarget:0:1}" = "/" ]; then
    # Check for static site type
    staticSiteTypeVar="STATICSITETYPE_$i"
    staticSiteType=$(eval "echo \${$staticSiteTypeVar}")
    if [[ "$staticSiteType" == "Gatsby" ]]; then
      vHostTemplate=$(cat /customization/vhost_static_gatsby.tpl)
    elif [[ "$staticSiteType" == "NextJS" ]]; then
      vHostTemplate=$(cat /customization/vhost_static_nextjs.tpl)
    else
      vHostTemplate=$(cat /customization/vhost_static.tpl)
    fi
    # Always generate redirect map conf and if-blocks for static sites.
    # Glob includes are silent no-ops when files don't exist yet;
    # nginx -s reload is all that's needed when .map files appear later.
    redirectMapVarSuffix=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
    mapOutput="/etc/nginx/sites/maps/${domain}.conf"
    build_redirect_map_conf "$domain" "$domainTarget" "$redirectMapVarSuffix" "$mapOutput"
    redirectsBlock="    if (\$redirect_301_${redirectMapVarSuffix}) { return 301 \$redirect_301_${redirectMapVarSuffix}_url; }
    if (\$redirect_302_${redirectMapVarSuffix}) { return 302 \$redirect_302_${redirectMapVarSuffix}_url; }"
  elif [ "${domainTarget:0:1}" = ">" ]; then
    vHostTemplate=$(cat /customization/vhost_redirect.tpl)  # begins with '>' -> temporary redirect (HTTP 302)
    domainTarget="${domainTarget:1}"                                    # remove '>' character
  else
    vHostTemplate=$(cat /customization/vhost_service.tpl) # else - serve service
    proxyResolverTemplate='    resolver 127.0.0.11 valid=300s ipv6=off;
    resolver_timeout 10s;'
    # --- SSE support ---
    sseVar="DOMAINSSE_$i"
    sseEndpoints=$(eval "echo \${$sseVar}")
    if [ -n "$sseEndpoints" ]; then
      for ssePath in $sseEndpoints; do
        sseLocationBlock=$(cat /customization/vhost_location_sse.tpl)
        sseLocationBlock=$(echo "$sseLocationBlock" | sed "s|\${ssePath}|$ssePath|g" | sed "s|\${target}|$domainTarget|g")
        sseLocationTemplate="${sseLocationTemplate}
${sseLocationBlock}
"
      done
    fi
    # --- WSS support ---
    wssVar="DOMAINWSS_$i"
    wssEndpoints=$(eval "echo \${$wssVar}")
    if [ -n "$wssEndpoints" ]; then
      for wssPath in $wssEndpoints; do
        wssLocationBlock=$(cat /customization/vhost_location_wss.tpl)
        wssLocationBlock=$(echo "$wssLocationBlock" | sed "s|\${wssPath}|$wssPath|g" | sed "s|\${target}|$domainTarget|g" | sed "s|\${maxUploadSize}|$maxUploadSize|g")
        wssLocationTemplate="${wssLocationTemplate}
${wssLocationBlock}
"
      done
    fi
    vHostTemplate=$(echo "${vHostTemplate//\${sseLocationTemplatePlaceholder\}/$sseLocationTemplate}")
    vHostTemplate=$(echo "${vHostTemplate//\${wssLocationTemplatePlaceholder\}/$wssLocationTemplate}")
  fi
  
  IFS=' '
  vHostTemplate=$(echo "${vHostTemplate//\$\{target\}/"$domainTarget"}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{index\}/"$domainTargetIndex"}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{maxUploadSize\}/"$maxUploadSize"}")
  vHostLocationTemplate=""

  i_location=1
  while true 
  do
    # Need to set DOMAIN_[...]_LOCATION_[...] , DOMAIN_[...]_LOCATION_[...]_TARGET
    # loop unit reach end of DOMAIN_[...]_LOCATION_[1,2,3,4]
    if [[ -z $(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}}") ]]; then
      break
    else
      domainLocation=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}}")
    fi
    if [[ -z $(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_TARGET}") ]]; then
      echo 'Error: Failed to construct nginx configuration files. DOMAINTARGET_${i} not found'
      break
    else
      domainLocationTarget=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_TARGET}")
    fi
    if [[ -z $(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_INDEX}") ]]; then
      domainTargetIndex="index.html"
    else
      domainTargetIndex=$(eval "echo \${DOMAIN_${i}_LOCATION_${i_location}_INDEX}")
    fi

    if [ "${domainLocationTarget:0:1}" = "/" ]; then
      vHostLocation=$(cat /customization/vhost_location_static.tpl)  # begins with '/' -> path -> serve static files
    else
      vHostLocation=$(cat /customization/vhost_location.tpl) # else - serve service
      proxyResolverTemplate='    resolver 127.0.0.11 valid=300s ipv6=off;
    resolver_timeout 10s;'
    fi
    vHostLocation=$(echo "${vHostLocation//\$\{location\}/"$domainLocation"}")
    vHostLocation=$(echo "${vHostLocation//\$\{locationTarget\}/"$domainLocationTarget"}")
    vHostLocation=$(echo "${vHostLocation//\$\{maxUploadSize\}/"$maxUploadSize"}")
    vHostLocation=$(echo "${vHostLocation//\$\{index\}/"$domainTargetIndex"}")
    vHostLocationTemplate="${vHostLocationTemplate} ${vHostLocation}"

    i_location=$((i_location+1))
  done
  vHostTemplate=$(echo "${vHostTemplate//\$\{proxyResolverTemplatePlaceholder\}/$proxyResolverTemplate}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{redirectsTemplatePlaceholder\}/"$redirectsBlock"}")
  vHostTemplate=$(echo "${vHostTemplate//\$\{locationTemplatePlaceholder\}/"$vHostLocationTemplate"}")


  echo "Rendering Nginx configuration file /etc/nginx/sites/$domain.conf"

  templateFile=$(cat /customization/site.conf.tpl)
  templateFile=$(echo "${templateFile//\$\{domain\}/"$domain"}")
  templateFile=$(echo "${templateFile//\$\{vhostinclude\}/"$vHostTemplate"}")
  echo "$templateFile" > "/etc/nginx/sites/$domain.conf"

  if [ ! -f "/etc/nginx/sites/ssl/dummy/$domain/fullchain.pem" ]; then
    echo "Generating dummy ceritificate for $domain"
    mkdir -p "/etc/nginx/sites/ssl/dummy/$domain"
    printf "[dn]\nCN=${domain}\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:$domain" > openssl.cnf
    openssl req -x509 -out "/etc/nginx/sites/ssl/dummy/$domain/fullchain.pem" -keyout "/etc/nginx/sites/ssl/dummy/$domain/privkey.pem" \
      -newkey rsa:2048 -nodes -sha256 \
      -subj "/CN=${domain}" -extensions EXT -config openssl.cnf
    rm -f openssl.cnf
  fi

  if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
    use_dummy_certificate "$domain"
    if [ "${NGINX_WAIT_FOR_LETSENCRYPT:-1}" != "0" ]; then
      wait_for_lets_encrypt "$domain" &
    else
      echo "Skipping Let's Encrypt wait loop for $domain"
    fi
  else
    use_lets_encrypt_certificate "$domain"
  fi


i=$((i+1))
done
exec nginx -g "daemon off;"
