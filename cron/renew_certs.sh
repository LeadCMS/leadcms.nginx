#!/bin/sh

cd /workdir

# shellcheck source=../scripts/compose-project.sh
. /workdir/scripts/compose-project.sh

PROJECT_NAME=$(resolve_compose_project)

echo "Renewing Let's Encrypt Certificates... (`date`) (project=$PROJECT_NAME)"
docker compose -p "$PROJECT_NAME" run --rm -T --entrypoint certbot certbot renew --no-random-sleep-on-renew || exit_code=$?

# reload.sh rather than a bare `nginx -s reload`: it re-renders first, so this
# nightly run also promotes any domain still on its dummy certificate to the
# real one, and it validates before reloading.
echo "Reloading Nginx configuration (project=$PROJECT_NAME)"
docker compose -p "$PROJECT_NAME" exec -T nginx /customization/reload.sh || reload_exit=$?

# Surface non-zero exit codes but don't break cron if renew skipped.
if [ -n "$exit_code" ] && [ "$exit_code" -ne 0 ]; then
	echo "certbot renew exited with code $exit_code"
fi
if [ -n "$reload_exit" ] && [ "$reload_exit" -ne 0 ]; then
	echo "nginx reload exited with code $reload_exit"
fi
