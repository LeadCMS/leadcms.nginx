#!/bin/sh

cd /workdir

# Ensure we operate on the SAME Compose project as the running stack.
# When executed on the host, the project name defaults to the basename of the directory
# (e.g. "onlinesales.nginx" -> sanitized to onlinesalesnginx). Inside this cron container
# the directory name is "workdir" so without -p we'd get a DIFFERENT project (new empty volumes),
# leading to "No renewals were attempted." and inability to exec into nginx.
# Override via COMPOSE_PROJECT_NAME if exported, else fall back to PROJECT_NAME env or a hardcoded default.

###############################################
# Resolve Docker Compose project name generically
# Priority order:
#  1. COMPOSE_PROJECT_NAME (standard compose override)
#  2. PROJECT_NAME_OVERRIDE (custom env you can inject)
#  3. Auto-detect from running nginx container label
#  4. Auto-detect from running certbot container label
#  5. Sanitize current directory basename (fallback)
###############################################

PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${PROJECT_NAME_OVERRIDE:-}}"

if [ -z "$PROJECT_NAME" ]; then
	PROJECT_NAME=$(docker ps --filter label=com.docker.compose.service=nginx \
		--format '{{.Label "com.docker.compose.project"}}' | head -n1 || true)
fi
if [ -z "$PROJECT_NAME" ]; then
	PROJECT_NAME=$(docker ps --filter label=com.docker.compose.service=certbot \
		--format '{{.Label "com.docker.compose.project"}}' | head -n1 || true)
fi
if [ -z "$PROJECT_NAME" ]; then
	# Fallback: use sanitized directory name (Compose default behavior) but directory
	# inside this container may be generic (e.g. workdir), so warn.
	raw_dir_name=$(basename "$(pwd)")
	PROJECT_NAME=$(echo "$raw_dir_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
	echo "Warning: Could not auto-detect running Compose project. Falling back to '$PROJECT_NAME' derived from directory '$raw_dir_name'. Set COMPOSE_PROJECT_NAME to override." >&2
fi

echo "Renewing Let's Encrypt Certificates... (`date`) (project=$PROJECT_NAME)"
docker compose -p "$PROJECT_NAME" run --rm -T --entrypoint certbot certbot renew --no-random-sleep-on-renew || exit_code=$?

echo "Reloading Nginx configuration (project=$PROJECT_NAME)"
docker compose -p "$PROJECT_NAME" exec -T nginx nginx -s reload || reload_exit=$?

# Surface non-zero exit codes but don't break cron if renew skipped.
if [ -n "$exit_code" ] && [ "$exit_code" -ne 0 ]; then
	echo "certbot renew exited with code $exit_code"
fi
if [ -n "$reload_exit" ] && [ "$reload_exit" -ne 0 ]; then
	echo "nginx reload exited with code $reload_exit"
fi
