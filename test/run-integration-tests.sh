#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE_CMD=(docker compose -p leadcms-nginx-test -f "$ROOT_DIR/docker-compose.test.yml")
REPORT_DIR="$ROOT_DIR/test-results"
# Mutable copy of config.env.test, bind-mounted into the running nginx so the
# hot reload cases can change configuration the way an operator does.
RUNTIME_CONFIG="$ROOT_DIR/test/runtime/config.env"
BUILD_STAMP="$ROOT_DIR/test/runtime/.build-stamp"
REPORT_FILE="$REPORT_DIR/nginx-integration.junit.xml"
REPORT_CASES_FILE=$(mktemp)
RESULTS_FILE=$(mktemp)
SUITE_START_TIME=$(date +%s)

TEST_COUNT=0
FAILURE_COUNT=0

HTTPS_PORT=""
TMP_DIR=""
rendered_main_conf=""
rendered_sites=""
nginx_warnings=""
cpu_count=""
expected_worker_processes=""
expected_worker_connections=""
expected_worker_rlimit_nofile=""

TEST_CASES=(
  "bootstrap environment::bootstrap_environment"
  "nginx has no warnings::test_nginx_no_warnings"
  "main nginx config tuning::test_main_nginx_config"
  "rendered site templates::test_rendered_sites"
  "plain static homepage::test_plain_static_homepage"
  "plain static custom 404::test_plain_static_custom_404"
  "plain static shared files::test_plain_static_shared_files"
  "gatsby html cache headers::test_gatsby_html_cache_headers"
  "gatsby asset cache headers::test_gatsby_asset_cache_headers"
  "nextjs route rendering::test_nextjs_route"
  "nextjs asset cache headers::test_nextjs_asset_cache_headers"
  "redirect target::test_redirect_rule"
  "plain static 301 redirect map::test_plain_static_redirect_301"
  "plain static 302 redirect map::test_plain_static_redirect_302"
  "plain static 301 redirect to external URL::test_plain_static_redirect_301_external"
  "plain static 302 redirect to external URL::test_plain_static_redirect_302_external"
  "service root proxy::test_service_root_proxy"
  "service api proxy::test_service_api_proxy"
  "service sse proxy::test_service_sse_proxy"
  "service wss proxy::test_service_wss_proxy"
  "worker process count matches config::test_running_worker_count"
  "basic auth domain unauthenticated::test_auth_domain_unauthenticated"
  "basic auth domain authenticated::test_auth_domain_authenticated"
  "basic auth domain wrong credentials::test_auth_domain_wrong_credentials"
  "basic auth location public path accessible::test_auth_location_public"
  "basic auth location protected unauthenticated::test_auth_location_unauthenticated"
  "basic auth location protected authenticated::test_auth_location_authenticated"
  "hot reload adds a domain::test_hot_reload_add_domain"
  "hot reload certbot preflight ordering::test_hot_reload_certbot_preflight"
  "hot reload removes a domain::test_hot_reload_remove_domain"
  "hot reload updates a live setting::test_hot_reload_update_setting"
  "hot reload dry run applies nothing::test_hot_reload_dry_run"
  "hot reload prunes a domain from the baked-in env::test_hot_reload_prunes_env_file_domain"
  "hot reload promotes a dummy certificate::test_hot_reload_certificate_promotion"
  "certbot skips a domain that already has a certificate::test_certbot_skips_existing_certificate"
  "hot reload rejects an invalid config::test_hot_reload_invalid_config"
)

KEEP_STACK=0
REUSE_STACK=0
WRITE_REPORT=1
ONLY_CASES=()

usage_runner() {
  cat <<'USAGE'
Usage: run-integration-tests.sh [options]

  --list       Print every test case name, one per line, and exit.
  --only NAME  Run only this case (repeatable). The bootstrap case always runs
               first, since every other case needs the stack it brings up.
  --reuse      Reuse an already running test stack instead of recreating it.
  --keep       Leave the stack running when the run finishes.
  --teardown   Tear the test stack down and exit.
  --no-report  Do not write the JUnit report.

With no options the whole suite runs against a freshly built stack, which is
what CI does. The other options exist so a single case can be run against a
stack that is already up — see test/test_integration.py.
USAGE
}

discard_temp_files() {
  rm -f "$REPORT_CASES_FILE" "$RESULTS_FILE"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      for test_case in "${TEST_CASES[@]}"; do
        echo "${test_case%%::*}"
      done
      discard_temp_files
      exit 0
      ;;
    --only)
      shift
      [ $# -gt 0 ] || { echo "run-integration-tests.sh: --only requires a value" >&2; exit 2; }
      ONLY_CASES[${#ONLY_CASES[@]}]="$1"
      ;;
    --only=*) ONLY_CASES[${#ONLY_CASES[@]}]="${1#--only=}" ;;
    --reuse) REUSE_STACK=1 ;;
    --keep) KEEP_STACK=1 ;;
    --no-report) WRITE_REPORT=0 ;;
    --teardown)
      "${COMPOSE_CMD[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
      discard_temp_files
      echo "Test stack torn down"
      exit 0
      ;;
    -h|--help) usage_runner; discard_temp_files; exit 0 ;;
    *) echo "run-integration-tests.sh: unknown option '$1'" >&2; usage_runner >&2; discard_temp_files; exit 2 ;;
  esac
  shift
done

SELECTED_CASES=()
if [[ ${#ONLY_CASES[@]} -eq 0 ]]; then
  SELECTED_CASES=("${TEST_CASES[@]}")
else
  selected_match_count=0
  bootstrap_requested=0
  for wanted in "${ONLY_CASES[@]}"; do
    [[ "$wanted" == "bootstrap environment" ]] && bootstrap_requested=1
  done
  for test_case in "${TEST_CASES[@]}"; do
    case_name=${test_case%%::*}
    if [[ "$case_name" == "bootstrap environment" ]]; then
      SELECTED_CASES[${#SELECTED_CASES[@]}]="$test_case"
      continue
    fi
    for wanted in "${ONLY_CASES[@]}"; do
      if [[ "$case_name" == "$wanted" ]]; then
        SELECTED_CASES[${#SELECTED_CASES[@]}]="$test_case"
        selected_match_count=$((selected_match_count + 1))
        break
      fi
    done
  done
  if [[ $selected_match_count -eq 0 && $bootstrap_requested -eq 0 ]]; then
    echo "run-integration-tests.sh: no test case matched --only. Use --list to see the available names." >&2
    discard_temp_files
    exit 2
  fi
fi
TOTAL_TESTS=${#SELECTED_CASES[@]}

stack_down() {
  "${COMPOSE_CMD[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}

stack_is_running() {
  "${COMPOSE_CMD[@]}" ps --status running --services 2>/dev/null | grep -qx nginx
}

# The container scripts are baked into the image, so reusing a stack built
# before an edit would silently test the old code. Anything newer than the
# stamp written at build time forces a rebuild.
stack_is_current() {
  local changed
  [[ -f "$BUILD_STAMP" ]] || return 1
  changed=$(find "$ROOT_DIR/nginx" "$ROOT_DIR/certbot" "$ROOT_DIR/docker-compose.test.yml" \
    "$ROOT_DIR/config.env.test" -newer "$BUILD_STAMP" -print -quit 2>/dev/null)
  [[ -z "$changed" ]]
}

cleanup_stack() {
  if [[ "$KEEP_STACK" == "1" ]]; then
    return 0
  fi
  stack_down
}

cleanup_resources() {
  cleanup_stack
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  rm -f "$REPORT_CASES_FILE"
  rm -f "$RESULTS_FILE"
}

dump_logs() {
  echo "--- nginx logs ---"
  "${COMPOSE_CMD[@]}" logs nginx || true
  echo "--- backend logs ---"
  "${COMPOSE_CMD[@]}" logs mock_backend || true
}

xml_escape() {
  local value=$1
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\"/&quot;}
  value=${value//$'\n'/&#10;}
  printf '%s' "$value"
}

write_junit_report() {
  if [[ "$WRITE_REPORT" != "1" ]]; then
    return 0
  fi
  mkdir -p "$REPORT_DIR"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    printf '<testsuite name="nginx-integration" tests="%s" failures="%s">\n' "$TEST_COUNT" "$FAILURE_COUNT"
    if [[ -f "$REPORT_CASES_FILE" ]]; then
      cat "$REPORT_CASES_FILE"
    fi
    echo '</testsuite>'
  } > "$REPORT_FILE"
}

finish() {
  write_junit_report
  cleanup_resources
}

trap dump_logs ERR
trap finish EXIT

print_suite_header() {
  echo "Nginx integration test suite"
  echo "Project: leadcms-nginx-test"
  if [[ "$WRITE_REPORT" == "1" ]]; then
    echo "Report:  $REPORT_FILE"
  fi
  echo
}

print_failure_output() {
  local output=$1
  if [[ -z "$output" ]]; then
    return 0
  fi

  echo "      failure details:"
  while IFS= read -r line; do
    printf '        %s\n' "$line"
  done <<< "$output"
}

print_suite_summary() {
  local suite_end_time passed_count
  suite_end_time=$(date +%s)
  passed_count=$((TEST_COUNT - FAILURE_COUNT))

  echo
  echo "Summary"
  echo "-------"
  printf '  total:  %s\n' "$TEST_COUNT"
  printf '  passed: %s\n' "$passed_count"
  printf '  failed: %s\n' "$FAILURE_COUNT"
  printf '  time:   %ss\n' "$((suite_end_time - SUITE_START_TIME))"
  if [[ "$WRITE_REPORT" == "1" ]]; then
    printf '  junit:  %s\n' "$REPORT_FILE"
  fi

  if [[ $FAILURE_COUNT -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Failed tests"
  echo "------------"
  while IFS=$'\t' read -r test_number name status elapsed; do
    if [[ "$status" == "FAIL" ]]; then
      printf '  [%02d/%02d] %s (%ss)\n' "$test_number" "$TOTAL_TESTS" "$name" "$elapsed"
    fi
  done < "$RESULTS_FILE"
}

run_test() {
  local name=$1
  local output_file output status start_time end_time elapsed escaped_name escaped_output test_number

  shift
  output_file=$(mktemp)
  test_number=$((TEST_COUNT + 1))
  printf '[%02d/%02d] %s ... ' "$test_number" "$TOTAL_TESTS" "$name"
  start_time=$(date +%s)
  set +e
  "$@" >"$output_file" 2>&1
  status=$?
  set -e
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  output=$(cat "$output_file")
  rm -f "$output_file"

  TEST_COUNT=$((TEST_COUNT + 1))
  escaped_name=$(xml_escape "$name")

  if [[ $status -eq 0 ]]; then
    printf '  <testcase classname="nginx.integration" name="%s" time="%s"/>\n' "$escaped_name" "$elapsed" >> "$REPORT_CASES_FILE"
    printf '%s\t%s\tPASS\t%s\n' "$test_number" "$name" "$elapsed" >> "$RESULTS_FILE"
    printf 'PASS (%ss)\n' "$elapsed"
    return 0
  fi

  FAILURE_COUNT=$((FAILURE_COUNT + 1))
  escaped_output=$(xml_escape "$output")
  {
    printf '  <testcase classname="nginx.integration" name="%s" time="%s">\n' "$escaped_name" "$elapsed"
    printf '    <failure message="Test failed">%s</failure>\n' "$escaped_output"
    echo '  </testcase>'
  } >> "$REPORT_CASES_FILE"
  printf '%s\t%s\tFAIL\t%s\n' "$test_number" "$name" "$elapsed" >> "$RESULTS_FILE"
  printf 'FAIL (%ss)\n' "$elapsed"
  print_failure_output "$output"
  return 0
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local message=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Assertion failed: $message"
    return 1
  fi
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  local message=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "Assertion failed: $message"
    return 1
  fi
}

assert_equals() {
  local expected=$1
  local actual=$2
  local message=$3
  if [[ "$actual" != "$expected" ]]; then
    echo "Assertion failed: $message"
    echo "Expected: $expected"
    echo "Actual:   $actual"
    return 1
  fi
}

request() {
  local host=$1
  local path=$2
  local output_prefix=$3
  curl -ksS --connect-timeout 5 --max-time 20 --resolve "$host:$HTTPS_PORT:127.0.0.1" "https://$host:$HTTPS_PORT$path" -D "$output_prefix.headers" -o "$output_prefix.body"
}

request_auth() {
  local host=$1
  local path=$2
  local output_prefix=$3
  local credentials=$4
  curl -ksS --connect-timeout 5 --max-time 20 --resolve "$host:$HTTPS_PORT:127.0.0.1" "https://$host:$HTTPS_PORT$path" -u "$credentials" -D "$output_prefix.headers" -o "$output_prefix.body"
}

assert_status() {
  local expected=$1
  local file=$2
  local actual
  actual=$(awk 'NR==1 {print $2}' "$file")
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected but got $actual"
    cat "$file"
    return 1
  fi
}

assert_header_contains() {
  local file=$1
  local needle=$2
  if ! grep -Fqi "$needle" "$file"; then
    echo "Missing header '$needle' in $file"
    cat "$file"
    return 1
  fi
}

assert_body_contains() {
  local file=$1
  local needle=$2
  if ! grep -Fq "$needle" "$file"; then
    echo "Missing body fragment '$needle' in $file"
    cat "$file"
    return 1
  fi
}

bootstrap_environment() {
  mkdir -p "$ROOT_DIR/test/runtime/letsencrypt" "$ROOT_DIR/test/runtime/certbot" "$REPORT_DIR"

  # Must exist before `up`, or Docker would create a directory at the mount point.
  reset_runtime_config

  # Create test htpasswd files for basic auth tests (generated fresh each run)
  mkdir -p "$ROOT_DIR/test/runtime/htpasswd"
  printf "testuser:%s\n" "$(openssl passwd -apr1 testpass)" > "$ROOT_DIR/test/runtime/htpasswd/auth-domain.local.test"
  cp "$ROOT_DIR/test/runtime/htpasswd/auth-domain.local.test" "$ROOT_DIR/test/runtime/htpasswd/auth-location.local.test"

  if [[ "$REUSE_STACK" == "1" ]] && stack_is_running && stack_is_current; then
    # Re-render from the pristine config so a single case starts from a known
    # state no matter what ran before it.
    echo "Reusing the running test stack"
    "${COMPOSE_CMD[@]}" exec -T nginx /customization/reload.sh >/dev/null 2>&1 || true
  else
    if [[ "$REUSE_STACK" == "1" ]] && stack_is_running; then
      echo "Sources changed since the last build; rebuilding the test stack"
    fi
    stack_down
    "${COMPOSE_CMD[@]}" up -d --build
    : > "$BUILD_STAMP"
  fi

  HTTPS_PORT=$("${COMPOSE_CMD[@]}" port nginx 443 | awk -F: 'NR==1 {print $NF}')
  if [[ -z "$HTTPS_PORT" ]]; then
    echo "Failed to determine published HTTPS port"
    return 1
  fi

  for _ in $(seq 1 90); do
    if curl -ksS --connect-timeout 5 --max-time 20 --resolve "plain.local.test:$HTTPS_PORT:127.0.0.1" "https://plain.local.test:$HTTPS_PORT/" -o /dev/null >/dev/null 2>&1; then
      break
    fi
    # Fail fast if the nginx container has already exited (e.g. config error)
    if ! "${COMPOSE_CMD[@]}" ps nginx | grep -q " Up \| running"; then
      echo "Nginx container exited during startup"
      echo "Nginx logs:"
      "${COMPOSE_CMD[@]}" logs nginx
      return 1
    fi
    sleep 1
  done

  if ! curl -ksS --connect-timeout 5 --max-time 20 --resolve "plain.local.test:$HTTPS_PORT:127.0.0.1" "https://plain.local.test:$HTTPS_PORT/" -o /dev/null >/dev/null; then
    echo "Nginx did not become ready on HTTPS"
    echo "Nginx logs:"
    "${COMPOSE_CMD[@]}" logs nginx
    return 1
  fi

  if ! "${COMPOSE_CMD[@]}" exec -T nginx nginx -t >/dev/null; then
    echo "nginx -t failed after startup"
    return 1
  fi

  nginx_warnings=$("${COMPOSE_CMD[@]}" exec -T nginx nginx -t 2>&1 | grep '\[warn\]' || true)

  rendered_main_conf=$("${COMPOSE_CMD[@]}" exec -T nginx cat /etc/nginx/nginx.conf)
  rendered_sites=$("${COMPOSE_CMD[@]}" exec -T nginx sh -c 'for file in /etc/nginx/sites/*.conf; do echo "###$file###"; cat "$file"; echo; done')
  cpu_count=$("${COMPOSE_CMD[@]}" exec -T nginx sh -c 'if command -v getconf >/dev/null 2>&1; then getconf _NPROCESSORS_ONLN; else grep -c "^processor" /proc/cpuinfo; fi')
  expected_worker_processes=$cpu_count
  expected_worker_connections=1536
  expected_worker_rlimit_nofile=$((expected_worker_processes * expected_worker_connections * 2))
  TMP_DIR=$(mktemp -d)
}

test_nginx_no_warnings() {
  if [[ -n "$nginx_warnings" ]]; then
    echo "Assertion failed: nginx -t produced warnings"
    echo "$nginx_warnings"
    return 1
  fi
}

test_main_nginx_config() {
  assert_contains "$rendered_main_conf" "worker_processes $expected_worker_processes;" 'worker_processes should default to container CPU count'
  assert_contains "$rendered_main_conf" "worker_rlimit_nofile $expected_worker_rlimit_nofile;" 'worker_rlimit_nofile should be derived from workers and worker_connections'
  assert_contains "$rendered_main_conf" "worker_connections $expected_worker_connections;" 'worker_connections override should be rendered'
  assert_contains "$rendered_main_conf" 'multi_accept off;' 'multi_accept override should be rendered'
  assert_contains "$rendered_main_conf" 'keepalive_timeout 9;' 'keepalive_timeout override should be rendered'
  assert_contains "$rendered_main_conf" 'keepalive_requests 321;' 'keepalive_requests override should be rendered'
  assert_contains "$rendered_main_conf" 'access_log /var/log/nginx/access.log main buffer=64k flush=2s;' 'access log buffering overrides should be rendered'
  assert_contains "$rendered_main_conf" 'open_file_cache max=7777 inactive=11s;' 'open_file_cache override should be rendered'
  assert_contains "$rendered_main_conf" 'open_file_cache_valid 13s;' 'open_file_cache_valid override should be rendered'
  assert_contains "$rendered_main_conf" 'open_file_cache_min_uses 5;' 'open_file_cache_min_uses override should be rendered'
}

test_rendered_sites() {
  assert_contains "$rendered_sites" 'server_name plain.local.test;' 'plain static server should be rendered'
  assert_contains "$rendered_sites" 'server_name gatsby.local.test;' 'gatsby static server should be rendered'
  assert_contains "$rendered_sites" 'server_name next.local.test;' 'next static server should be rendered'
  assert_contains "$rendered_sites" 'server_name redirect.local.test;' 'redirect server should be rendered'
  assert_contains "$rendered_sites" 'server_name service.local.test;' 'service server should be rendered'
  assert_contains "$rendered_sites" 'location /events {' 'SSE location should be rendered'
  assert_contains "$rendered_sites" 'location /socket.io {' 'WSS location should be rendered'
  assert_contains "$rendered_sites" 'return 302 https://plain.local.test$request_uri;' 'redirect target should be rendered'
  assert_contains "$rendered_sites" 'if ($redirect_301_plain_local_test)' 'plain static 301 redirect if-block should be rendered'
  assert_contains "$rendered_sites" 'return 301 $redirect_301_plain_local_test_url' 'plain static 301 redirect should use url variable'
  assert_contains "$rendered_sites" 'if ($redirect_302_plain_local_test)' 'plain static 302 redirect if-block should be rendered'
  assert_contains "$rendered_sites" 'return 302 $redirect_302_plain_local_test_url' 'plain static 302 redirect should use url variable'
  assert_contains "$rendered_sites" 'server_name auth-domain.local.test;' 'auth domain server should be rendered'
  assert_contains "$rendered_sites" 'auth_basic_user_file /etc/nginx/htpasswd/auth-domain.local.test;' 'auth domain should have htpasswd file configured'
  assert_contains "$rendered_sites" 'server_name auth-location.local.test;' 'auth location server should be rendered'
  assert_contains "$rendered_sites" 'auth_basic_user_file /etc/nginx/htpasswd/auth-location.local.test;' 'auth location sub-location should have htpasswd file configured'
}

test_plain_static_homepage() {
  request plain.local.test / "$TMP_DIR/plain"
  assert_status 200 "$TMP_DIR/plain.headers"
  assert_body_contains "$TMP_DIR/plain.body" 'Plain Static'
}

test_plain_static_custom_404() {
  request plain.local.test /missing "$TMP_DIR/plain404"
  assert_status 404 "$TMP_DIR/plain404.headers"
  assert_body_contains "$TMP_DIR/plain404.body" 'Plain 404'
}

test_plain_static_shared_files() {
  request plain.local.test /files/download.txt "$TMP_DIR/files"
  assert_status 200 "$TMP_DIR/files.headers"
  assert_body_contains "$TMP_DIR/files.body" 'shared-file-ok'
  assert_header_contains "$TMP_DIR/files.headers" 'Content-Type: text/plain'
}

test_gatsby_html_cache_headers() {
  request gatsby.local.test / "$TMP_DIR/gatsby"
  assert_status 200 "$TMP_DIR/gatsby.headers"
  assert_body_contains "$TMP_DIR/gatsby.body" 'Gatsby Static'
  assert_header_contains "$TMP_DIR/gatsby.headers" 'Cache-Control: public, max-age=0, must-revalidate'
}

test_gatsby_asset_cache_headers() {
  request gatsby.local.test /app.js "$TMP_DIR/gatsby_asset"
  assert_status 200 "$TMP_DIR/gatsby_asset.headers"
  assert_header_contains "$TMP_DIR/gatsby_asset.headers" 'Cache-Control: public, max-age=31536000, immutable'
}

test_nextjs_route() {
  request next.local.test /about "$TMP_DIR/next_about"
  assert_status 200 "$TMP_DIR/next_about.headers"
  assert_body_contains "$TMP_DIR/next_about.body" 'Next About'
}

test_nextjs_asset_cache_headers() {
  request next.local.test /_next/static/app.js "$TMP_DIR/next_asset"
  assert_status 200 "$TMP_DIR/next_asset.headers"
  assert_header_contains "$TMP_DIR/next_asset.headers" 'Cache-Control: public, max-age=31536000, immutable'
}

test_redirect_rule() {
  request redirect.local.test /docs "$TMP_DIR/redirect"
  assert_status 302 "$TMP_DIR/redirect.headers"
  assert_header_contains "$TMP_DIR/redirect.headers" 'Location: https://plain.local.test/docs'
}

test_plain_static_redirect_301() {
  request plain.local.test /old-page/ "$TMP_DIR/plain_redirect_301"
  assert_status 301 "$TMP_DIR/plain_redirect_301.headers"
  local location
  location=$(grep -i '^Location:' "$TMP_DIR/plain_redirect_301.headers" | tr -d '\r')
  assert_contains "$location" '/index.html' '301 redirect Location should point to /index.html'
}

test_plain_static_redirect_302() {
  request plain.local.test /temp-gone/ "$TMP_DIR/plain_redirect_302"
  assert_status 302 "$TMP_DIR/plain_redirect_302.headers"
  local location
  location=$(grep -i '^Location:' "$TMP_DIR/plain_redirect_302.headers" | tr -d '\r')
  assert_contains "$location" '/index.html' '302 redirect Location should point to /index.html'
}

test_plain_static_redirect_301_external() {
  request plain.local.test /external-301/ "$TMP_DIR/plain_redirect_301_ext"
  assert_status 301 "$TMP_DIR/plain_redirect_301_ext.headers"
  local location
  location=$(grep -i '^Location:' "$TMP_DIR/plain_redirect_301_ext.headers" | tr -d '\r')
  assert_contains "$location" 'https://www.example.com/external-page/' '301 redirect to external URL Location should be the absolute URL'
  assert_not_contains "$location" 'plain.local.test' '301 redirect to external URL should not prepend the local host'
}

test_plain_static_redirect_302_external() {
  request plain.local.test /external-302/ "$TMP_DIR/plain_redirect_302_ext"
  assert_status 302 "$TMP_DIR/plain_redirect_302_ext.headers"
  local location
  location=$(grep -i '^Location:' "$TMP_DIR/plain_redirect_302_ext.headers" | tr -d '\r')
  assert_contains "$location" 'https://www.example.com/promo/' '302 redirect to external URL Location should be the absolute URL'
  assert_not_contains "$location" 'plain.local.test' '302 redirect to external URL should not prepend the local host'
}

test_service_root_proxy() {
  request service.local.test / "$TMP_DIR/service"
  assert_status 200 "$TMP_DIR/service.headers"
  assert_body_contains "$TMP_DIR/service.body" 'backend-root'
}

test_service_api_proxy() {
  request service.local.test /api "$TMP_DIR/service_api"
  assert_status 200 "$TMP_DIR/service_api.headers"
  assert_body_contains "$TMP_DIR/service_api.body" '"path": "/api"'
}

test_service_sse_proxy() {
  request service.local.test /events "$TMP_DIR/service_sse"
  assert_status 200 "$TMP_DIR/service_sse.headers"
  assert_header_contains "$TMP_DIR/service_sse.headers" 'Content-Type: text/event-stream'
  assert_body_contains "$TMP_DIR/service_sse.body" 'backend-sse'
}

test_service_wss_proxy() {
  request service.local.test /socket.io "$TMP_DIR/service_wss"
  assert_status 200 "$TMP_DIR/service_wss.headers"
  assert_body_contains "$TMP_DIR/service_wss.body" 'backend-wss-route'
}

test_running_worker_count() {
  local nginx_worker_processes
  nginx_worker_processes=$("${COMPOSE_CMD[@]}" exec -T nginx sh -c 'ps | grep "nginx: worker process" | grep -v grep | wc -l | tr -d " "')
  assert_equals "$expected_worker_processes" "$nginx_worker_processes" 'running nginx worker count should match the rendered worker_processes value'
}

test_auth_domain_unauthenticated() {
  request auth-domain.local.test / "$TMP_DIR/auth_domain_unauth"
  assert_status 401 "$TMP_DIR/auth_domain_unauth.headers"
  assert_header_contains "$TMP_DIR/auth_domain_unauth.headers" 'WWW-Authenticate:'
}

test_auth_domain_authenticated() {
  request_auth auth-domain.local.test / "$TMP_DIR/auth_domain_auth" "testuser:testpass"
  assert_status 200 "$TMP_DIR/auth_domain_auth.headers"
  assert_body_contains "$TMP_DIR/auth_domain_auth.body" 'backend-root'
}

test_auth_domain_wrong_credentials() {
  request_auth auth-domain.local.test / "$TMP_DIR/auth_domain_wrong" "testuser:wrongpass"
  assert_status 401 "$TMP_DIR/auth_domain_wrong.headers"
}

test_auth_location_public() {
  request auth-location.local.test / "$TMP_DIR/auth_loc_public"
  assert_status 200 "$TMP_DIR/auth_loc_public.headers"
  assert_body_contains "$TMP_DIR/auth_loc_public.body" 'backend-root'
}

test_auth_location_unauthenticated() {
  request auth-location.local.test /api "$TMP_DIR/auth_loc_unauth"
  assert_status 401 "$TMP_DIR/auth_loc_unauth.headers"
  assert_header_contains "$TMP_DIR/auth_loc_unauth.headers" 'WWW-Authenticate:'
}

test_auth_location_authenticated() {
  request_auth auth-location.local.test /api "$TMP_DIR/auth_loc_auth" "testuser:testpass"
  assert_status 200 "$TMP_DIR/auth_loc_auth.headers"
  assert_body_contains "$TMP_DIR/auth_loc_auth.body" '"path": "/api"'
}

# --- hot reload -------------------------------------------------------------
#
# These cases edit test/runtime/config.env — the file bind-mounted into the
# running container — and apply it with reload.sh, exactly the way
# apply-config.sh does in production.
#
# Each one starts from the pristine config and restores it, so any single case
# can be run on its own (from the VS Code test explorer, say) in any order.

HOT_RELOAD_DOMAIN="hotreload.local.test"

nginx_master_pid() {
  "${COMPOSE_CMD[@]}" exec -T nginx cat /var/run/nginx.pid | tr -d '[:space:]'
}

reload_nginx_config() {
  "${COMPOSE_CMD[@]}" exec -T nginx /customization/reload.sh
}

running_config() {
  "${COMPOSE_CMD[@]}" exec -T nginx nginx -T 2>/dev/null
}

append_runtime_config() {
  printf '%s\n' "$@" >> "$RUNTIME_CONFIG"
}

reset_runtime_config() {
  cp "$ROOT_DIR/config.env.test" "$RUNTIME_CONFIG"
  # config.env.test ends without a newline; without this an appended setting
  # would be glued onto the last line and silently ignored.
  printf '\n' >> "$RUNTIME_CONFIG"
}

add_static_domain() {
  local index=$1 domain=$2
  append_runtime_config "" \
    "DOMAIN_${index}=\"$domain\"" \
    "DOMAINTARGET_${index}=\"/var/www/html/plain.local.test\"" \
    "CERTBOTEMAIL_${index}=\"\""
}

# Stands in for certbot: promotion is driven purely by the directory appearing
# under /etc/letsencrypt/live, which is a bind mount from the host.
issue_fake_certificate() {
  local domain=$1 certDir="$ROOT_DIR/test/runtime/letsencrypt/live/$1"
  mkdir -p "$certDir"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=$domain" -keyout "$certDir/privkey.pem" -out "$certDir/fullchain.pem" >/dev/null 2>&1
}

discard_fake_certificate() {
  rm -rf "$ROOT_DIR/test/runtime/letsencrypt/live/$1"
}

begin_hot_reload_case() {
  reset_runtime_config
  reload_nginx_config >/dev/null
}

end_hot_reload_case() {
  reset_runtime_config
  reload_nginx_config >/dev/null
}

test_hot_reload_add_domain() {
  local pid_before pid_after

  begin_hot_reload_case
  pid_before=$(nginx_master_pid)

  add_static_domain 8 "$HOT_RELOAD_DOMAIN"
  if ! reload_nginx_config; then
    echo "reload.sh failed for a valid configuration"
    return 1
  fi

  request "$HOT_RELOAD_DOMAIN" / "$TMP_DIR/hot_add"
  assert_status 200 "$TMP_DIR/hot_add.headers"
  assert_body_contains "$TMP_DIR/hot_add.body" 'Plain Static'

  if ! "${COMPOSE_CMD[@]}" exec -T nginx test -f "/etc/nginx/sites/maps/$HOT_RELOAD_DOMAIN.conf"; then
    echo "the redirect map wrapper should be generated for a hot-added static site"
    return 1
  fi

  pid_after=$(nginx_master_pid)
  assert_equals "$pid_before" "$pid_after" 'the nginx master process should survive the reload (hot reload, not restart)'

  end_hot_reload_case
}

test_hot_reload_remove_domain() {
  local running_conf

  begin_hot_reload_case
  add_static_domain 8 "$HOT_RELOAD_DOMAIN"
  reload_nginx_config >/dev/null

  running_conf=$(running_config)
  assert_contains "$running_conf" "server_name $HOT_RELOAD_DOMAIN;" 'the domain should be served before it is removed'

  reset_runtime_config
  if ! reload_nginx_config; then
    echo "reload.sh failed while removing a domain"
    return 1
  fi

  running_conf=$(running_config)
  assert_not_contains "$running_conf" "server_name $HOT_RELOAD_DOMAIN;" 'a domain removed from config.env should no longer be served'

  request plain.local.test / "$TMP_DIR/hot_remove"
  assert_status 200 "$TMP_DIR/hot_remove.headers"
}

# The container's environment still holds the copy Compose baked in at creation
# time, so removing a domain only works if that stale copy is cleared before
# config.env is re-read.
test_hot_reload_prunes_env_file_domain() {
  local running_conf filtered

  begin_hot_reload_case

  filtered=$(grep -vE '^(DOMAIN_7|DOMAINTARGET_7|CERTBOTEMAIL_7)' "$RUNTIME_CONFIG")
  printf '%s\n' "$filtered" > "$RUNTIME_CONFIG"

  if ! reload_nginx_config; then
    echo "reload.sh failed while removing a domain that is present in env_file"
    return 1
  fi

  running_conf=$(running_config)
  assert_not_contains "$running_conf" 'server_name auth-location.local.test;' 'a domain removed from config.env must not survive in the baked-in environment'

  end_hot_reload_case

  running_conf=$(running_config)
  assert_contains "$running_conf" 'server_name auth-location.local.test;' 'restoring the domain should bring the vhost back'
}

test_hot_reload_update_setting() {
  local running_conf

  begin_hot_reload_case

  sed -i.bak 's/^NGINX_UPLOADSIZE_MAX=.*/NGINX_UPLOADSIZE_MAX=33M/' "$RUNTIME_CONFIG"
  rm -f "$RUNTIME_CONFIG.bak"

  if ! reload_nginx_config; then
    echo "reload.sh failed while changing NGINX_UPLOADSIZE_MAX"
    return 1
  fi

  running_conf=$(running_config)
  assert_contains "$running_conf" 'client_max_body_size 33M;' 'a changed upload limit should be live after the reload'

  end_hot_reload_case
}

test_hot_reload_dry_run() {
  local output running_before running_after

  begin_hot_reload_case
  running_before=$(running_config)

  add_static_domain 8 dryrun.local.test

  output=$("${COMPOSE_CMD[@]}" exec -T nginx /customization/render.sh --dry-run 2>&1)
  assert_contains "$output" '+ dryrun.local.test.conf' 'the dry run should list the vhost it would add'
  assert_contains "$output" '2 added, 0 removed, 0 changed' 'the dry run should summarise exactly what changes'

  if "${COMPOSE_CMD[@]}" exec -T nginx test -f /etc/nginx/sites/dryrun.local.test.conf; then
    echo "the dry run wrote a vhost to the live configuration directory"
    return 1
  fi

  running_after=$(running_config)
  assert_equals "$running_before" "$running_after" 'the dry run must not change the running configuration'

  end_hot_reload_case
}

test_hot_reload_certificate_promotion() {
  local domain="promoted.local.test" conf

  begin_hot_reload_case
  discard_fake_certificate "$domain"

  add_static_domain 8 "$domain"
  reload_nginx_config >/dev/null

  conf=$("${COMPOSE_CMD[@]}" exec -T nginx cat "/etc/nginx/sites/$domain.conf")
  assert_contains "$conf" "ssl_certificate /etc/nginx/sites/ssl/dummy/$domain/fullchain.pem;" 'a domain without a certificate should serve the self-signed placeholder'

  issue_fake_certificate "$domain"

  if ! reload_nginx_config; then
    echo "reload.sh failed after the certificate appeared"
    return 1
  fi

  conf=$("${COMPOSE_CMD[@]}" exec -T nginx cat "/etc/nginx/sites/$domain.conf")
  assert_contains "$conf" "ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;" 'the reload should promote the domain to its Let'"'"'s Encrypt certificate'

  request "$domain" / "$TMP_DIR/hot_promote"
  assert_status 200 "$TMP_DIR/hot_promote.headers"

  discard_fake_certificate "$domain"
  end_hot_reload_case
}

test_hot_reload_certbot_preflight() {
  local output status

  begin_hot_reload_case

  # A domain nginx already serves: its ACME challenge path must answer.
  add_static_domain 8 "$HOT_RELOAD_DOMAIN"
  reload_nginx_config >/dev/null

  status=0
  output=$("${COMPOSE_CMD[@]}" run --rm -T certbot --preflight-only --domains "$HOT_RELOAD_DOMAIN" 2>&1) || status=$?
  if [[ $status -ne 0 ]]; then
    echo "Preflight should succeed for a domain nginx already serves (exit $status)"
    echo "$output"
    end_hot_reload_case
    return 1
  fi
  assert_contains "$output" "Preflight OK for $HOT_RELOAD_DOMAIN" 'certbot should report the challenge path as reachable'

  # A domain present in config.env but not yet rendered must be refused rather
  # than spending one of Let's Encrypt's five failed validations per hour.
  add_static_domain 9 unrendered.local.test

  status=0
  output=$("${COMPOSE_CMD[@]}" run --rm -T certbot --preflight-only --domains unrendered.local.test 2>&1) || status=$?
  if [[ $status -eq 0 ]]; then
    echo "Preflight should fail for a domain nginx does not serve yet"
    echo "$output"
    end_hot_reload_case
    return 1
  fi
  assert_contains "$output" 'not reachable through nginx' 'certbot should explain why the domain was skipped'

  end_hot_reload_case
}

test_certbot_skips_existing_certificate() {
  local domain="preprovisioned.local.test" output status=0

  begin_hot_reload_case

  add_static_domain 8 "$domain"
  reload_nginx_config >/dev/null
  issue_fake_certificate "$domain"

  output=$("${COMPOSE_CMD[@]}" run --rm -T certbot --domains "$domain" 2>&1) || status=$?

  discard_fake_certificate "$domain"
  end_hot_reload_case

  if [[ $status -ne 0 ]]; then
    echo "certbot should exit cleanly when the requested domain already has a certificate (exit $status)"
    echo "$output"
    return 1
  fi
  assert_contains "$output" 'already has a certificate' 'certbot should skip a domain that is already provisioned'
  assert_not_contains "$output" 'Obtaining the certificate' 'certbot must not request a certificate it already holds'
}

test_hot_reload_invalid_config() {
  local pid_before pid_after rendered_conf

  begin_hot_reload_case
  pid_before=$(nginx_master_pid)

  append_runtime_config 'NGINX_KEEPALIVE_TIMEOUT="not-a-duration"'

  if reload_nginx_config >/dev/null 2>&1; then
    echo "reload.sh accepted a configuration nginx cannot parse"
    end_hot_reload_case
    return 1
  fi

  pid_after=$(nginx_master_pid)
  assert_equals "$pid_before" "$pid_after" 'a rejected reload must not restart nginx'

  rendered_conf=$("${COMPOSE_CMD[@]}" exec -T nginx cat /etc/nginx/nginx.conf)
  assert_contains "$rendered_conf" 'keepalive_timeout 9;' 'the previous nginx.conf should be restored after a rejected reload'

  # Traffic is unaffected: nginx never loaded the broken configuration.
  request plain.local.test / "$TMP_DIR/hot_invalid"
  assert_status 200 "$TMP_DIR/hot_invalid.headers"

  end_hot_reload_case
}

print_suite_header

for test_case in "${SELECTED_CASES[@]}"; do
  test_name=${test_case%%::*}
  test_function=${test_case##*::}

  if [[ "$test_function" != "bootstrap_environment" && $FAILURE_COUNT -ne 0 && -z "$TMP_DIR" ]]; then
    break
  fi

  run_test "$test_name" "$test_function"
done

print_suite_summary

if [[ $FAILURE_COUNT -eq 0 ]]; then
  echo
  echo "Integration tests passed"
  exit 0
fi

echo
echo "Integration tests failed: $FAILURE_COUNT of $TEST_COUNT test cases failed"
exit 1