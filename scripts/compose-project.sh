# POSIX sh snippet, sourced by apply-config.sh (host) and cron/renew_certs.sh
# (inside the cron container). Not executable on its own.
#
# Both need to talk to the SAME Compose project as the running stack. On the
# host the project name defaults to the sanitized directory basename, but inside
# the cron container the directory is /workdir, so without resolving it
# explicitly we would address a different project with empty volumes.
#
# Priority order:
#  1. COMPOSE_PROJECT_NAME (standard compose override)
#  2. PROJECT_NAME_OVERRIDE (custom env you can inject)
#  3. Auto-detect from a running stack started from this very directory
#  4. Auto-detect from the running nginx container label
#  5. Auto-detect from the running certbot container label
#  6. Sanitized current directory basename (fallback)
resolve_compose_project() {
	resolved="${COMPOSE_PROJECT_NAME:-${PROJECT_NAME_OVERRIDE:-}}"

	# Most precise: a stack whose Compose working directory is this one. Skipped
	# implicitly inside the cron container, where pwd is /workdir and nothing matches.
	if [ -z "$resolved" ]; then
		resolved=$(docker ps --filter "label=com.docker.compose.project.working_dir=$(pwd)" \
			--format '{{.Label "com.docker.compose.project"}}' | head -n1 || true)
	fi
	if [ -z "$resolved" ]; then
		resolved=$(docker ps --filter label=com.docker.compose.service=nginx \
			--format '{{.Label "com.docker.compose.project"}}' | head -n1 || true)
	fi
	if [ -z "$resolved" ]; then
		resolved=$(docker ps --filter label=com.docker.compose.service=certbot \
			--format '{{.Label "com.docker.compose.project"}}' | head -n1 || true)
	fi
	if [ -z "$resolved" ]; then
		raw_dir_name=$(basename "$(pwd)")
		resolved=$(echo "$raw_dir_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
		echo "Warning: Could not auto-detect running Compose project. Falling back to '$resolved' derived from directory '$raw_dir_name'. Set COMPOSE_PROJECT_NAME to override." >&2
	fi

	echo "$resolved"
}
