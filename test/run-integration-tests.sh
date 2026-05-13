#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE_CMD=(docker compose -p leadcms-nginx-test -f "$ROOT_DIR/docker-compose.test.yml")
REPORT_DIR="$ROOT_DIR/test-results"
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
  "service root proxy::test_service_root_proxy"
  "service api proxy::test_service_api_proxy"
  "service sse proxy::test_service_sse_proxy"
  "service wss proxy::test_service_wss_proxy"
  "worker process count matches config::test_running_worker_count"
)
TOTAL_TESTS=${#TEST_CASES[@]}

cleanup_stack() {
  "${COMPOSE_CMD[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
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
  echo "Report:  $REPORT_FILE"
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
  printf '  junit:  %s\n' "$REPORT_FILE"

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

  cleanup_stack
  "${COMPOSE_CMD[@]}" up -d --build

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
  assert_contains "$rendered_sites" 'return 301 $scheme://$http_host$redirect_301_plain_local_test' 'plain static 301 redirect should use scheme and host'
  assert_contains "$rendered_sites" 'if ($redirect_302_plain_local_test)' 'plain static 302 redirect if-block should be rendered'
  assert_contains "$rendered_sites" 'return 302 $scheme://$http_host$redirect_302_plain_local_test' 'plain static 302 redirect should use scheme and host'
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

print_suite_header

for test_case in "${TEST_CASES[@]}"; do
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