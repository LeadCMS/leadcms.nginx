#!/bin/bash
# Applies config.env to the running stack without restarting anything.
#
#   ./apply-config.sh              render + hot reload, then issue certificates
#                                  for domains that are still missing one
#   ./apply-config.sh --dry-run    show what would change, apply nothing
#   ./apply-config.sh --no-certs   configuration only, skip certbot entirely
#   ./apply-config.sh --domains a.com,b.com
#                                  limit certificate issuance to these domains
#
# Ordering matters and is enforced here: nginx has to be serving
# /.well-known/acme-challenge/ for a new domain *before* certbot asks Let's
# Encrypt to validate it. Everything is done with `nginx -s reload`, so no
# connection is dropped and the other domains are never interrupted.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"

# shellcheck source=scripts/compose-project.sh
. "$ROOT_DIR/scripts/compose-project.sh"

CONFIG_FILE="$ROOT_DIR/config.env"
dryRun=0
skipCerts=0
domains=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dryRun=1 ;;
    --no-certs) skipCerts=1 ;;
    --domains)
      shift
      [ $# -gt 0 ] || { echo "apply-config.sh: --domains requires a value" >&2; exit 2; }
      domains=$1
      ;;
    --domains=*) domains=${1#--domains=} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "apply-config.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$CONFIG_FILE" ]; then
  echo "apply-config.sh: $CONFIG_FILE not found" >&2
  exit 1
fi

# Catch an unterminated quote or stray character before it reaches the
# container. Parses only — nothing in config.env is executed.
if ! bash -n "$CONFIG_FILE"; then
  echo "apply-config.sh: $CONFIG_FILE is not valid shell syntax; nothing was applied" >&2
  exit 1
fi

PROJECT_NAME=$(resolve_compose_project)
COMPOSE=(docker compose -p "$PROJECT_NAME")

if ! "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx nginx; then
  echo "apply-config.sh: the nginx service of project '$PROJECT_NAME' is not running." >&2
  echo "Start the stack first with: docker compose up -d" >&2
  exit 1
fi

if [ "$dryRun" = "1" ]; then
  echo "==> Pending configuration changes (project=$PROJECT_NAME)"
  "${COMPOSE[@]}" exec -T nginx /customization/render.sh --dry-run
  exit 0
fi

echo "==> Rendering and hot-reloading nginx (project=$PROJECT_NAME)"
"${COMPOSE[@]}" exec -T nginx /customization/reload.sh

if [ "$skipCerts" = "1" ]; then
  echo "==> Skipping certificate issuance (--no-certs)"
  exit 0
fi

certbotArgs=(--only-missing)
if [ -n "$domains" ]; then
  certbotArgs=(--domains "$domains")
fi

echo "==> Issuing certificates for domains that do not have one"
certbotStatus=0
"${COMPOSE[@]}" run --rm -T certbot "${certbotArgs[@]}" || certbotStatus=$?

echo "==> Reloading nginx to pick up any newly issued certificate"
"${COMPOSE[@]}" exec -T nginx /customization/reload.sh

if [ "$certbotStatus" -ne 0 ]; then
  echo
  echo "apply-config.sh: certbot reported a problem (exit $certbotStatus)." >&2
  echo "The configuration is live; the affected domains are serving the self-signed" >&2
  echo "placeholder certificate until issuance succeeds. Re-run once the cause is fixed:" >&2
  echo "  ./apply-config.sh --domains <domain>" >&2
  exit "$certbotStatus"
fi

echo "==> Done"
