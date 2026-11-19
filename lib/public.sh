#!/usr/bin/env bash
# What `grm-status --json --public` sends, field by field: an allow-list, for
# a status document that leaves this machine (docs/status-json.md#public-output).
# Source after lib/common.sh.
#
# Every field `grm-status --json` prints has a class here. test/status-json.bats
# fails on a field without one, and grm-status refuses to print it in public.
#   keep     sent as is: numbers, states, times, process ids and names
#   alias    a stand-in (runner-1, repo-2, other); the real value with
#            GRM_RELAY_SHARE_DETAILS=1
#   share    null, or "" where the schema needs a string; the real value with
#            GRM_RELAY_SHARE_DETAILS=1
#   numeric  event detail in the numeric forms the gates write, else ""; as
#            is with GRM_RELAY_SHARE_DETAILS=1
#   never    always a stand-in: paths, user names, runner labels
declare -grA PUBLIC_FIELDS=(
  [schema]=keep [generated_at]=keep
  [host.cpus]=keep [host.load_1m]=keep [host.max_load]=keep
  [host.memory_available_mb]=keep [host.min_memory_mb]=keep
  [runners.name]=alias [runners.repository]=alias [runners.units]=keep
  [runners.labels]=never [runners.unit]=alias [runners.unit_state]=keep
  [runners.worker_pid]=keep
  [workers.pid]=keep [workers.directory]=never
  [slots.capacity]=keep [slots.used]=keep [slots.max_wait_seconds]=keep
  [slots.records.kind]=keep [slots.records.ticket]=keep [slots.records.holder_pid]=keep
  [slots.records.units]=keep [slots.records.label]=alias [slots.records.since]=keep
  [slots.records.unparking]=keep
  [slots.records.job.repository]=alias [slots.records.job.workflow]=share
  [slots.records.job.job]=share [slots.records.job.run_id]=share
  [slots.records.job.run_attempt]=share [slots.records.job.ref]=share
  [slots.records.job.head_ref]=share [slots.records.job.sha]=share
  [slots.records.job.event]=share [slots.records.job.actor]=never
  [slots.records.job.runner]=alias [slots.records.job.server_url]=share
  [slots.records.job.pull_request]=share [slots.records.job.pull_request_title]=share
  [slots.records.job.queued_at]=keep
  [device_lock.state]=keep
  [device_lock.holder.repository]=alias [device_lock.holder.run_id]=share
  [device_lock.holder.job]=share [device_lock.holder.pid]=keep
  [device_lock.holder.since]=keep [device_lock.holder.alive]=keep
  [device_lock.watchdog.min_age_seconds]=keep [device_lock.watchdog.kill]=keep
  [device_lock.watchdog.stale.pid]=keep [device_lock.watchdog.stale.fd]=keep
  [device_lock.watchdog.stale.age_seconds]=keep [device_lock.watchdog.stale.command]=keep
  [events.at]=keep [events.kind]=keep [events.subject]=alias [events.detail]=numeric
)

# Words the gates use in event details (docs/events.md); with numbers, the
# only text a public detail may hold.
declare -grA PUBLIC_DETAIL_WORDS=(
  [units]=1 [was]=1 [holding]=1 [queued]=1 [parked]=1 [returned]=1 [while]=1
  [waiting]=1 [for]=1 [the]=1 [device]=1 [ticket]=1 [asks]=1 [back]=1
  [admitted]=1 [after]=1 [max]=1 [wait]=1 [used]=1 ['line(s)']=1 [dropped]=1
  [from]=1 [state]=1 [file]=1 [pid]=1 [age]=1 [fd]=1 [sent]=1 [TERM]=1 [by]=1
  [watchdog]=1 [held]=1 [busy]=1 [gave]=1 [up]=1 [waiter]=1 [gone]=1
)

# Set to 1 by `grm-status --json --public`; public_field does nothing otherwise.
public_output=${public_output:-0}

# In public output, replaces the raw value in the variable named $1, field $2
# of the document, as the field's class says. The stand-in is the output of
# the remaining arguments run with the value appended, or empty without them.
# A field without a class stops the output (exit 70): nothing unclassified
# leaves the machine.
public_field() {
  ((public_output)) || return 0
  local -n public_value=$1
  local path=$2
  shift 2
  case ${PUBLIC_FIELDS[$path]:-} in
    keep) return 0;;
    alias|share|numeric) [[ ${GRM_RELAY_SHARE_DETAILS:-0} != 1 ]] || return 0;;
    never) ;;
    *) printf 'grm-status: field %s has no public class (lib/public.sh)\n' "$path" >&2; exit 70;;
  esac
  if (($#)); then public_value=$("$@" "$public_value"); else public_value=''; fi
}

# "path class" for every classified field.
public_classes() {
  local path
  for path in "${!PUBLIC_FIELDS[@]}"; do printf '%s %s\n' "$path" "${PUBLIC_FIELDS[$path]}"; done
}

# runner-N for the Nth configured runner, other for any other name.
public_runner_alias() {
  local name=$1 entry configured index=0
  [[ -n $name ]] || return 0
  for entry in "${GRM_RUNNERS[@]}"; do
    index=$((index + 1))
    read -r configured _ <<< "$entry"
    if [[ $configured == "$name" ]]; then printf 'runner-%s' "$index"; return; fi
  done
  printf 'other'
}

# repo-N for the Nth distinct repository in the runner config, other for any
# other repository or slot label.
public_repository_alias() {
  local name=$1 entry repository index=0
  local -A seen=()
  [[ -n $name ]] || return 0
  for entry in "${GRM_RUNNERS[@]}"; do
    read -r _ repository _ <<< "$entry"
    [[ -n $repository && -z ${seen[$repository]:-} ]] || continue
    index=$((index + 1)) seen[$repository]=1
    if [[ $repository == "$name" ]]; then printf 'repo-%s' "$index"; return; fi
  done
  printf 'other'
}

# A runner's unit takes the runner's alias.
public_unit_alias() {
  local name=${1#"$GRM_UNIT_PREFIX"}
  name=$(public_runner_alias "${name%.service}")
  printf '%s.service' "${name:-other}"
}

# A worker directory is a path: it becomes the alias of the runner that lives
# there, or other.
public_directory_alias() {
  local directory=$1 entry name
  for entry in "${GRM_RUNNERS[@]}"; do
    read -r name _ <<< "$entry"
    if [[ $(readlink -f "$GRM_RUNNERS_DIR/$name" 2>/dev/null) == "$directory" ]]; then
      public_runner_alias "$name"
      return
    fi
  done
  printf 'other'
}

# An event subject is a slot label or repository, except the process name of
# a stale holder and the fixed word of a corrupt state file.
public_subject() {
  case $1 in
    stale|kill|corrupt) printf '%s' "$2";;
    *) public_repository_alias "$2";;
  esac
}

# The detail itself when every word is a number or one of the gates' words,
# else nothing.
public_detail() {
  local word
  local -a words
  read -r -a words <<< "$1"
  for word in "${words[@]}"; do
    word=${word%[,;]}
    [[ $word =~ ^[0-9]+(s|/[0-9]+)?$ || -n ${PUBLIC_DETAIL_WORDS[$word]:-} ]] || return 0
  done
  printf '%s' "$1"
}
