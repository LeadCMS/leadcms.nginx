#!/bin/bash
# Issues Let's Encrypt certificates for configured domains.
#
# Only domains that do not have a certificate yet are touched, so this is cheap
# to re-run against a stack that is already fully provisioned — adding one
# domain costs one certificate request, not fifty-four.

set -e

trap exit INT TERM

nginxHost="${CERTBOT_NGINX_HOST:-nginx}"
requestedDomains=""
preflightOnly=0

usage() {
  cat <<'USAGE'
Usage: certbot.sh [--only-missing] [--domains a.com,b.com] [--preflight-only]

  --only-missing    Issue certificates for every configured domain that does
                    not have one yet. This is the default.
  --domains LIST    Restrict the run to a comma or space separated list of
                    domains. Domains that already have a certificate are still
                    skipped.
  --preflight-only  Only check that each domain's ACME challenge path is
                    reachable through nginx. Issues nothing.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only-missing) ;;
    --preflight-only) preflightOnly=1 ;;
    --domains)
      shift
      [ $# -gt 0 ] || { echo "certbot.sh: --domains requires a value" >&2; exit 2; }
      requestedDomains=$(echo "$1" | tr ',' ' ')
      ;;
    --domains=*) requestedDomains=$(echo "${1#--domains=}" | tr ',' ' ') ;;
    -h|--help) usage; exit 0 ;;
    *) echo "certbot.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

is_requested() {
  local domain=$1 candidate
  [ -z "$requestedDomains" ] && return 0
  for candidate in $requestedDomains; do
    [ "$candidate" = "$domain" ] && return 0
  done
  return 1
}

dns_resolves() {
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" >/dev/null 2>&1
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "$1" >/dev/null 2>&1
  else
    return 0
  fi
}

# Confirms nginx is already serving this domain's ACME webroot before spending a
# request. Let's Encrypt allows only 5 failed validations per hostname per hour,
# and the usual cause of a failure — issuing before nginx knows about the new
# vhost — is exactly what this catches.
preflight_domain() {
  local domain=$1 challengeDir token ok=1
  challengeDir="/var/www/certbot/$domain/.well-known/acme-challenge"
  mkdir -p "$challengeDir"
  token="leadcms-preflight-$$-$(date +%s)"
  echo "$token" > "$challengeDir/$token"

  if curl -sf --max-time 10 -H "Host: $domain" \
      "http://${nginxHost}/.well-known/acme-challenge/${token}" 2>/dev/null | grep -qx "$token"; then
    ok=0
  fi

  rm -f "$challengeDir/$token"
  return $ok
}

until nc -z "$nginxHost" 80; do
  echo "Waiting for nginx to start..."
  sleep 5s & wait ${!}
done

if [ "$CERTBOT_TEST_CERT" != "0" ]; then
  test_cert_arg="--test-cert"
fi

issued=""
skipped=""
failed=""
failureCount=0

i=1
while true
do
  # Need to set DOMAIN_[...] , CERTBOTEMAIL_[...]
  # loop unit reach end of DOMAIN_[1,2,3,4]
  if [[ -z $(eval "echo \${DOMAIN_$i}") ]]; then
    break
  else
    domain=$(eval "echo \${DOMAIN_$i}")
  fi

  mkdir -p "/var/www/certbot/$domain"

  if ! is_requested "$domain"; then
    i=$((i+1))
    continue
  fi

  if [ -d "/etc/letsencrypt/live/$domain" ] && [ "$preflightOnly" = "0" ]; then
    echo "Let's Encrypt certificate for $domain already exists"
    skipped="$skipped  skipped  $domain (already has a certificate)
"
    i=$((i+1))
    continue
  fi

  if ! dns_resolves "$domain"; then
    echo "Warning: $domain does not resolve yet; Let's Encrypt validation will fail if DNS is still missing"
  fi

  if ! preflight_domain "$domain"; then
    echo "Skipping $domain: its ACME challenge path is not reachable through nginx yet"
    skipped="$skipped  skipped  $domain (ACME challenge not reachable through nginx)
"
    failureCount=$((failureCount+1))
    i=$((i+1))
    continue
  fi

  if [ "$preflightOnly" = "1" ]; then
    echo "Preflight OK for $domain"
    issued="$issued  reachable  $domain
"
    i=$((i+1))
    continue
  fi

  if [[ -z $(eval "echo \${CERTBOTEMAIL_$i}") ]]; then
    email_arg="--register-unsafely-without-email"
    echo "Obtaining the certificate for $domain without email"
  else
    email=$(eval "echo \${CERTBOTEMAIL_$i}")
    email_arg="--email $email"
    echo "Obtaining the certificate for $domain with email $email"
  fi

  if certbot certonly \
    --webroot \
    -w "/var/www/certbot/$domain" \
    -d "$domain" \
    $test_cert_arg \
    $email_arg \
    --rsa-key-size "${CERTBOT_RSA_KEY_SIZE:-4096}" \
    --agree-tos \
    --noninteractive \
    --verbose; then
    issued="$issued  issued   $domain
"
  else
    echo "Failed to obtain a certificate for $domain"
    failed="$failed  failed   $domain
"
    failureCount=$((failureCount+1))
  fi

i=$((i+1))
done

echo
echo "Certificate summary:"
printf '%s%s%s' "$issued" "$skipped" "$failed"
if [ -z "$issued$skipped$failed" ]; then
  echo "  nothing to do"
fi

# A failure here must not be silent: apply-config.sh reports it to the operator
# instead of leaving a domain stuck on its dummy certificate unnoticed.
exit $((failureCount > 0 ? 1 : 0))
