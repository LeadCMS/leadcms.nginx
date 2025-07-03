#!/bin/bash

set -e

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
  sseLocationTemplate=""
  wssLocationTemplate=""
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
  elif [ "${domainTarget:0:1}" = ">" ]; then
    vHostTemplate=$(cat /customization/vhost_redirect.tpl)  # begins with '>' -> temporary redirect (HTTP 302)
    domainTarget="${domainTarget:1}"                                    # remove '>' character
  else
    vHostTemplate=$(cat /customization/vhost_service.tpl) # else - serve service
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
    fi
    vHostLocation=$(echo "${vHostLocation//\$\{location\}/"$domainLocation"}")
    vHostLocation=$(echo "${vHostLocation//\$\{locationTarget\}/"$domainLocationTarget"}")
    vHostLocation=$(echo "${vHostLocation//\$\{maxUploadSize\}/"$maxUploadSize"}")
    vHostLocation=$(echo "${vHostLocation//\$\{index\}/"$domainTargetIndex"}")
    vHostLocationTemplate="${vHostLocationTemplate} ${vHostLocation}"

    i_location=$((i_location+1))
  done
  vHostTemplate=$(echo "${vHostTemplate//\$\{locationTemplatePlaceholder\}/"$vHostLocationTemplate"}")


  if [ ! -f "/etc/nginx/sites/$domain.conf" ]; then
    echo "Creating Nginx configuration file /etc/nginx/sites/$domain.conf"

    templateFile=$(cat /customization/site.conf.tpl)
    templateFile=$(echo "${templateFile//\$\{domain\}/"$domain"}")
    templateFile=$(echo "${templateFile//\$\{vhostinclude\}/"$vHostTemplate"}")
    echo "$templateFile" > "/etc/nginx/sites/$domain.conf"
  fi

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
    wait_for_lets_encrypt "$domain" &
  else
    use_lets_encrypt_certificate "$domain"
  fi


i=$((i+1))
done
exec nginx -g "daemon off;"
