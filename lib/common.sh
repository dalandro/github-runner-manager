#!/usr/bin/env bash
# Shared configuration and Linux process identity. Bash 4.4+.
# Precedence: exported environment > sourced config > defaults.
# GRM_RUNNERS is a Bash array in the config (arrays cannot be exported).
# Test seam GRM_PROC affects loadavg/meminfo only; identities always use /proc.

GRM_ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")

load_config() {
  local name index
  local -a names=() values=()
  while IFS= read -r name; do
    [[ $name == GRM_* ]] || continue
    names+=("$name")
    values+=("${!name}")
  done < <(compgen -e)
  GRM_CONFIG=${GRM_CONFIG:-$GRM_ROOT/config.env}
  if [[ -f $GRM_CONFIG ]]; then
    # shellcheck source=/dev/null
    source "$GRM_CONFIG"
  fi
  for index in "${!names[@]}"; do
    printf -v "${names[index]}" '%s' "${values[index]}"
    export "${names[index]}"
  done
  GRM_CONFIG=$(readlink -m "$GRM_CONFIG")
  : "${GRM_RUNNERS_DIR:=$HOME/runners}"
  if ! declare -p GRM_RUNNERS &>/dev/null; then GRM_RUNNERS=(); fi
  : "${GRM_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/github-runner-manager}"
  : "${GRM_SLOTS_CAPACITY:=6}" "${GRM_SLOTS_MAX_WAIT:=2700}" "${GRM_SLOTS_POLL:=1}"
  : "${GRM_DEVICE_LOCK:=$GRM_STATE_DIR/device.lock}"
  : "${GRM_DEVICE_LOCK_TIMEOUT:=3600}" "${GRM_DEVICE_LOCK_GRACE:=5}"
  : "${GRM_DEVICE_LOCK_PARK:=1}"
  : "${GRM_MAX_LOAD:=$(getconf _NPROCESSORS_ONLN)}"
  : "${GRM_MIN_MEM_MB:=3072}" "${GRM_LOAD_TIMEOUT:=1800}"
  : "${GRM_WATCHDOG_MIN_AGE:=600}" "${GRM_WATCHDOG_KILL:=0}"
  : "${GRM_WATCHDOG_KILL_ALLOW:=}" "${GRM_UNIT_PREFIX:=grm-runner-}"
  : "${GRM_SYSTEMD_USER_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
  : "${GRM_SYSTEMCTL:=systemctl --user}" "${GRM_PROC:=/proc}"
  : "${GRM_EVENTS_MAX:=500}"
}
load_config

get_start_time() {
  local stat
  local -a fields
  [[ $1 =~ ^[0-9]+$ ]] || return 0
  { IFS= read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 0
  read -r -a fields <<< "${stat##*) }"
  [[ ${fields[0]:-Z} != Z && ${fields[0]:-X} != X ]] || return 0
  printf '%s\n' "${fields[19]:-}"
}

is_alive() {
  [[ -n $2 && $(get_start_time "$1") == "$2" ]]
}

# Report current-user flock holders without opening or taking the lock.
find_lock_holders() {
  local lock=$1 directory descriptor number
  for directory in /proc/[0-9]*; do
    [[ -O $directory ]] || continue
    for descriptor in "$directory"/fd/*; do
      [[ $descriptor -ef $lock ]] || continue
      number=${descriptor##*/}
      # fdinfo follows the open file description after the flock process exits.
      awk '$1 == "lock:" && /FLOCK/ {found=1} END {exit !found}' "$directory/fdinfo/$number" 2>/dev/null || continue
      printf '%s %s\n' "${directory##*/}" "$number"
    done
  done
}

# Test seam: GRM_WORKER_COMM renames the worker process to look for, so tests
# that run inside a real Actions job do not find the job's own worker.
find_worker_pid() {
  local process=$$ comm stat
  local -a fields
  while [[ $process =~ ^[0-9]+$ ]] && ((process > 1)); do
    { IFS= read -r comm < "/proc/$process/comm"; } 2>/dev/null || break
    if [[ $comm == "${GRM_WORKER_COMM:-Runner.Worker}" ]]; then printf '%s\n' "$process"; return; fi
    { IFS= read -r stat < "/proc/$process/stat"; } 2>/dev/null || break
    read -r -a fields <<< "${stat##*) }"
    process=${fields[1]:-0}
  done
  return 0
}

# Report flock holders other than the legitimate wrapper once their process age
# reaches the minimum, one "pid fd age start comm" line each. Never signals anything.
find_stale_lock_holders() {
  local lock=$1 min_age=$2 legitimate_holder=$3 uptime ticks process number start age comm
  read -r uptime _ < /proc/uptime
  ticks=$(getconf CLK_TCK)
  while read -r process number; do
    [[ $process != "$legitimate_holder" ]] || continue
    start=$(get_start_time "$process")
    [[ -n $start ]] || continue
    age=$(awk -v uptime="$uptime" -v start="$start" -v ticks="$ticks" 'BEGIN {printf "%.0f", int(uptime - start / ticks)}')
    ((age >= min_age)) || continue
    { IFS= read -r comm < "/proc/$process/comm"; } 2>/dev/null || continue
    printf '%s %s %s %s %s\n' "$process" "$number" "$age" "$start" "$comm"
  done < <(find_lock_holders "$lock")
}

# Append "epoch kind subject detail" to the bounded event log read by the status
# views. Best effort: logging never fails or delays a gate beyond a short flock.
# The log is rewritten in place under events.lock, never replaced.
log_event() {
  local kind=$1 subject=${2:-unknown} detail=${3:-} events_fd count kept
  if ! is_uint "$GRM_EVENTS_MAX" || ((GRM_EVENTS_MAX == 0)); then return 0; fi
  subject=${subject//[[:space:]]/_}
  detail=${detail//[[:cntrl:]]/ }
  (
    mkdir -p "$GRM_STATE_DIR"
    exec {events_fd}>"$GRM_STATE_DIR/events.lock"
    flock "$events_fd"
    printf '%s %s %s %s\n' "$(date +%s)" "$kind" "${subject:-unknown}" "$detail" >> "$GRM_STATE_DIR/events.log"
    count=$(wc -l < "$GRM_STATE_DIR/events.log")
    if ((count > GRM_EVENTS_MAX * 2)); then
      kept=$(tail -n "$GRM_EVENTS_MAX" "$GRM_STATE_DIR/events.log")
      printf '%s\n' "$kept" > "$GRM_STATE_DIR/events.log"
    fi
  ) 2>/dev/null || true
}

notice() { printf '::notice::%s\n' "$*"; }
warning() { printf '::warning::%s\n' "$*" >&2; }
error() { printf '::error::%s\n' "$*" >&2; }
usage_error() { error "$*"; exit 2; }
is_uint() { [[ $1 =~ ^(0|[1-9][0-9]*)$ && ${#1} -le 9 ]]; }
is_number() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }

systemctl_user() {
  local -a systemctl_arguments
  read -r -a systemctl_arguments <<< "$GRM_SYSTEMCTL"
  "${systemctl_arguments[@]}" "$@"
}

get_load_and_memory() {
  local load available
  { read -r load _ < "$GRM_PROC/loadavg"; } 2>/dev/null || return 1
  is_number "$load" || return 1
  available=$(awk '$1 == "MemAvailable:" {print $2; exit}' "$GRM_PROC/meminfo" 2>/dev/null) || return 1
  is_uint "$available" || return 1
  printf '%s %s\n' "$load" "$((available / 1024))"
}

get_runner_units() {
  local entry name repository units extra
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && $GRM_UNIT_PREFIX =~ ^[a-zA-Z0-9._-]+$ ]] || usage_error 'invalid runner name or unit prefix'
  for entry in "${GRM_RUNNERS[@]}"; do
    read -r name repository units _ extra <<< "$entry"
    [[ $name == "$1" ]] || continue
    is_uint "$units" && ((units > 0)) && [[ -n $repository && -z $extra ]] || usage_error 'invalid runner configuration'
    printf '%s\n' "$units"
    return 0
  done
  usage_error "unknown runner: $1"
}

# WorkingDirectory is a path, not a systemd quoted string.
systemd_working_directory() {
  local value=$1
  [[ $value != [[:space:]]* && $value != *[[:space:]] && $value != *$'\n'* && $value != *$'\r'* ]] || usage_error 'directory paths must not contain edge whitespace or newlines'
  printf '%s' "${value//%/%%}"
}

# A systemd quoted string; ExecStart additionally expands dollar signs.
quote_systemd() {
  local value=$1
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || usage_error 'paths must not contain newlines'
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  if [[ ${2:-} == exec ]]; then value=${value//\$/\$\$}; fi
  printf '"%s"' "$value"
}

render_template() {
  local template=$1 line token value
  shift
  local -a replacements=("$@")
  local index
  while IFS= read -r line || [[ -n $line ]]; do
    for ((index=0; index<${#replacements[@]}; index+=2)); do
      token=${replacements[index]} value=${replacements[index+1]}
      if [[ $line == *"$token"* ]]; then line="${line%%"$token"*}$value${line#*"$token"}"; fi
    done
    printf '%s\n' "$line"
  done < "$template"
}

write_runner_env() {
  local file=$1 mode=$2 units=${3:-} temporary
  if [[ $mode == uninstall && -f $file ]] && ! grep -Eq '^(ACTIONS_RUNNER_HOOK_JOB_STARTED|ACTIONS_RUNNER_HOOK_JOB_COMPLETED|GRM_JOB_UNITS|GRM_CONFIG)=' "$file"; then return 0; fi
  temporary=$(mktemp "$(dirname "$file")/.env.XXXXXX")
  if [[ -f $file ]]; then
    awk '!/^(ACTIONS_RUNNER_HOOK_JOB_STARTED|ACTIONS_RUNNER_HOOK_JOB_COMPLETED|GRM_JOB_UNITS|GRM_CONFIG)=/' "$file" > "$temporary"
  fi
  if [[ $mode == install ]]; then
    printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s/hooks/job-started\nACTIONS_RUNNER_HOOK_JOB_COMPLETED=%s/hooks/job-completed\nGRM_JOB_UNITS=%s\n' "$GRM_ROOT" "$GRM_ROOT" "$units" >> "$temporary"
    if [[ -f $GRM_CONFIG ]]; then printf 'GRM_CONFIG=%s\n' "$GRM_CONFIG" >> "$temporary"; fi
  fi
  chmod 600 "$temporary"
  mv -f "$temporary" "$file"
}
