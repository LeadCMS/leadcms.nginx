#!/bin/bash
# Container entrypoint: render the configuration once, then run nginx.
#
# All rendering lives in lib.sh/render.sh so that the exact same code path is
# used at startup and by reload.sh against an already running container. See
# ../README.md for how to apply config.env changes without a restart.

set -e

# shellcheck source=lib.sh
. /customization/lib.sh

load_config

certificate_state() {
  ls -1 "$LETSENCRYPT_DIR/live" 2>/dev/null | sort | tr '\n' ' '
}

# Promotes domains from their dummy certificate to the real one as soon as
# certbot issues it. A single watcher replaces the previous one-background-loop-
# per-domain approach, which spawned a process for every domain still waiting.
watch_certificates() {
  local interval=${NGINX_CERT_WATCH_INTERVAL:-10}
  local last current

  while [ ! -s /var/run/nginx.pid ]; do
    sleep 1s & wait ${!}
  done

  last=$(certificate_state)
  while true; do
    sleep "${interval}s" & wait ${!}
    current=$(certificate_state)
    if [ "$current" != "$last" ]; then
      last=$current
      echo "Let's Encrypt certificates changed; re-rendering and reloading"
      /customization/reload.sh || echo "Reload after certificate change failed; keeping the running configuration"
    fi
  done
}

ensure_dhparam

/customization/render.sh

if [ "${NGINX_WAIT_FOR_LETSENCRYPT:-1}" != "0" ]; then
  watch_certificates &
else
  echo "Skipping the Let's Encrypt certificate watcher"
fi

exec nginx -g "daemon off;"
