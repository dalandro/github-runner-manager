#!/usr/bin/env bats
load helpers

# Runs the hosted relay image (dashboard/Dockerfile) as Fly would, but
# published on 127.0.0.1 only, and checks what the internet would see. Needs
# Docker and an image built beforehand, named in GRM_RELAY_IMAGE:
#
#   docker build -t grm-relay dashboard && GRM_RELAY_IMAGE=grm-relay bats test/relay-image.bats
#
# Skipped otherwise; CI builds the image and runs it.
export BATS_TEST_TIMEOUT=120
port=${GRM_RELAY_SMOKE_PORT:-4391}
public_host=relay.example.dev
token=example-push-token-of-32-characters
password=example-viewer-password
demo=$BATS_TEST_DIRNAME/../dashboard/priv/demo/status.json

# The status code of a request to the relay under its public name, or under
# $request_host; the body goes to $BATS_TEST_TMPDIR/body and the headers to
# $BATS_TEST_TMPDIR/headers.
request() {
  curl -sS --noproxy '*' --max-time 5 -o "$BATS_TEST_TMPDIR/body" -D "$BATS_TEST_TMPDIR/headers" \
    -w '%{http_code}' -H "Host: ${request_host:-$public_host}" "$@"
}
header() { grep -i "^$1:" "$BATS_TEST_TMPDIR/headers" | tr -d '\r'; }

setup_file() {
  [[ -n ${GRM_RELAY_IMAGE:-} ]] || return 0
  container=grm-relay-smoke-$$
  echo "$container" > "$BATS_FILE_TMPDIR/container"
  docker run -d --rm --name "$container" -p "127.0.0.1:$port:8080" \
    -e GRM_RELAY_PUBLIC_HOST=$public_host -e GRM_RELAY_PUSH_TOKENS=$token \
    -e GRM_RELAY_VIEWER_PASSWORD=$password \
    -e SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 -w0)" \
    "$GRM_RELAY_IMAGE" > /dev/null
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if curl -fsS --noproxy '*' -o /dev/null "http://127.0.0.1:$port/robots.txt" 2> /dev/null; then return 0; fi
    sleep 1
  done
  docker logs "$container" >&2
  return 1
}

teardown_file() {
  [[ -r $BATS_FILE_TMPDIR/container ]] || return 0
  docker stop -t 5 "$(cat "$BATS_FILE_TMPDIR/container")" > /dev/null 2>&1 || true
}

setup() {
  [[ -n ${GRM_RELAY_IMAGE:-} ]] || skip 'GRM_RELAY_IMAGE is not set (build dashboard/Dockerfile first)'
  container=$(cat "$BATS_FILE_TMPDIR/container")
  url=http://127.0.0.1:$port
}

@test "relay image runs as a user other than root, with nothing but the web port open" {
  run docker exec "$container" id -u
  [ "$status" -eq 0 ]
  [ "$output" != 0 ]
  # Port 8080 in hex, listening; no Erlang distribution port beside it.
  run docker exec "$container" sh -c 'cat /proc/net/tcp /proc/net/tcp6 | awk "\$4 == \"0A\" {print \$2}"'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *':1F90' ]]
}

@test "relay image answers its health check and keeps out of search engines" {
  request_host=172.19.0.2 run request "$url/robots.txt"
  [ "$output" = 200 ]
  grep -q 'Disallow: /' "$BATS_TEST_TMPDIR/body"
  [[ $(header x-robots-tag) == *'noindex, nofollow' ]]
  [[ $(header strict-transport-security) == *'max-age=31536000' ]]
}

@test "relay image shows the board only for the viewer password" {
  # A push lands first, so there is something to hide.
  run request -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary "@$demo" "$url/ingest"
  [ "$output" = 200 ]

  run request "$url/"
  [ "$output" = 401 ]
  [[ $(header www-authenticate) == *'Basic realm="runner status"'* ]]
  ! grep -q 'org/' "$BATS_TEST_TMPDIR/body"

  run request -H 'Fly-Client-IP: 198.51.100.20' -u "viewer:$password-wrong" "$url/"
  [ "$output" = 401 ]
  ! grep -q 'org/' "$BATS_TEST_TMPDIR/body"

  # The board reads the latest push once a second.
  local attempt
  for ((attempt=0; attempt<10; attempt++)); do
    run request -u "viewer:$password" "$url/"
    [ "$output" = 200 ]
    if grep -q 'org/mobile-app' "$BATS_TEST_TMPDIR/body"; then break; fi
    sleep 0.5
  done
  grep -q 'org/mobile-app' "$BATS_TEST_TMPDIR/body"
  [[ $(header set-cookie) == *'; secure'*'; HttpOnly; SameSite=Strict' ]]

  # The live socket connects with that sign-in (its cookie is Secure, so it
  # is sent by hand over this plain loopback port), and without it refuses
  # to connect at all.
  local cookie csrf
  cookie=$(header set-cookie | sed -e 's/^[^:]*: //' -e 's/;.*//')
  csrf=$(grep -o 'name="csrf-token" content="[^"]*"' "$BATS_TEST_TMPDIR/body" | sed 's/.*content="//; s/"$//')
  [[ -n $cookie && -n $csrf ]]
  run request --max-time 2 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: https://$public_host" -H "Cookie: $cookie" \
    "$url/live/websocket?vsn=2.0.0&_csrf_token=$csrf"
  # curl gives up on the open socket after 2 s; the status is the last line.
  [ "${lines[-1]}" = 101 ]
  run request -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: https://$public_host" \
    "$url/live/websocket?vsn=2.0.0&_csrf_token=$csrf"
  [ "$output" = 403 ]

  # Under any other name nothing is served (DNS rebinding).
  request_host=other.example.dev run request -u "viewer:$password" "$url/"
  [ "$output" = 403 ]
}

@test "relay image refuses a push without the token" {
  run request -X POST -H "Authorization: Bearer $token-wrong" -H 'Content-Type: application/json' \
    --data-binary "@$demo" "$url/ingest"
  [ "$output" = 401 ]
  run request -X POST -H 'Content-Type: application/json' --data-binary "@$demo" "$url/ingest"
  [ "$output" = 401 ]
}

@test "relay image locks out a client after ten wrong passwords" {
  local attempt
  for ((attempt=1; attempt<=10; attempt++)); do
    run request -H 'Fly-Client-IP: 198.51.100.30' -u "viewer:wrong-$attempt" "$url/"
    [ "$output" = 401 ]
  done
  run request -H 'Fly-Client-IP: 198.51.100.30' -u "viewer:$password" "$url/"
  [ "$output" = 429 ]
  [[ $(header retry-after) == *600 ]]
  ! grep -q 'org/' "$BATS_TEST_TMPDIR/body"

  run request -H 'Fly-Client-IP: 198.51.100.31' -u "viewer:$password" "$url/"
  [ "$output" = 200 ]
}

@test "relay image logs neither the password nor the token" {
  run docker logs "$container"
  [ "$status" -eq 0 ]
  [[ $output != *"$password"* && $output != *"$token"* ]]
  [[ $output != *"$(printf 'viewer:%s' "$password" | base64)"* ]]
}

@test "relay image refuses to start in public without a viewer password or a lasting secret" {
  run timeout 60 docker run --rm -e GRM_RELAY_PUBLIC_HOST=$public_host -e GRM_RELAY_PUSH_TOKENS=$token \
    -e SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 -w0)" "$GRM_RELAY_IMAGE"
  [ "$status" -ne 0 ]
  [[ $output == *'GRM_RELAY_VIEWER_PASSWORD'* ]]

  run timeout 60 docker run --rm -e GRM_RELAY_PUBLIC_HOST=$public_host -e GRM_RELAY_PUSH_TOKENS=$token \
    -e GRM_RELAY_VIEWER_PASSWORD=$password "$GRM_RELAY_IMAGE"
  [ "$status" -ne 0 ]
  [[ $output == *'SECRET_KEY_BASE'* && $output != *"$password"* ]]
}
