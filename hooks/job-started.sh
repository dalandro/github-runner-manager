#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
holder=$(find_worker_pid)
if [[ ${1:-} == --holder && $# == 2 ]]; then
  holder=$2
elif (($#)); then
  usage_error 'usage: job-started.sh [--holder PID]'
fi
[[ -n $holder ]] || usage_error 'job-started.sh must run as a runner job hook; use --holder for manual use'
write_job_record "$holder"
exec "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units "${GRM_JOB_UNITS:-1}" --label "${GITHUB_REPOSITORY:-job}"
