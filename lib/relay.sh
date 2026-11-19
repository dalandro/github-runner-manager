#!/usr/bin/env bash
# The pure parts of bin/grm-relay-push (docs/relay-push.md). Source after
# lib/common.sh.

# The protocol curl may use for a relay URL: https, or http to this machine
# only (a relay on loopback, for testing). Fails for anything else.
relay_url_protocol() {
  local path='(/[^[:space:]"\\]*)?' port='(:[0-9]{1,5})?'
  if [[ $1 =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$port$path$ ]]; then
    printf 'https'
  elif [[ $1 =~ ^http://(127\.0\.0\.1|\[::1\])$port$path$ ]]; then
    printf 'http'
  else
    return 1
  fi
}

# Seconds until the next push: what the relay's reply asks for, clamped to
# 2..300, or 5 when the reply does not say.
relay_next_interval() {
  local seconds
  if [[ $1 =~ \"next_push_seconds\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    seconds=${BASH_REMATCH[1]}
    seconds=${seconds#"${seconds%%[!0]*}"}
    if ((${#seconds} > 3)); then seconds=300; fi
    seconds=$((10#${seconds:-0}))
    ((seconds >= 2)) || seconds=2
    ((seconds <= 300)) || seconds=300
    printf '%s' "$seconds"
  else
    printf '5'
  fi
}

# Seconds to wait after the Nth failure in a row ($1): the interval ($2)
# doubled N times, at most 300, less up to a quarter by the random number $3
# (0..32767), so many hosts do not retry in step.
relay_backoff() {
  local failures=$1 delay=$2 step
  for ((step = 0; step < failures && delay < 300; step++)); do delay=$((delay * 2)); done
  ((delay <= 300)) || delay=300
  printf '%s' $((delay - $3 % (delay / 4 + 1)))
}

# The push token: the first line of a file only this account may read, 32 or
# more visible characters without quotes or backslashes (it goes into a curl
# config). Errors never repeat the file's content.
relay_read_token() {
  local file=$1 mode token
  if [[ ! -f $file || ! -r $file ]]; then
    printf 'no readable push token file at %s\n' "$file" >&2
    return 1
  fi
  mode=$(stat -L -c '%a' "$file")
  if [[ ! -O $file ]] || ((8#$mode & 8#077)); then
    printf 'push token file %s must be this account'\''s alone (chmod 600)\n' "$file" >&2
    return 1
  fi
  IFS= read -r token < "$file" || true
  if [[ ! $token =~ ^[[:graph:]]{32,}$ || $token == *[\"\\]* ]]; then
    printf 'push token in %s must be one line of 32 or more visible characters, without quotes or backslashes\n' "$file" >&2
    return 1
  fi
  printf '%s' "$token"
}
