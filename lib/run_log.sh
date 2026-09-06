#!/usr/bin/env bash
# lib/run_log.sh — 定期ジョブ共通ログ規約: run_id境界 + last-run.json + rotation
# (cmd_767・halsk/automation scripts/lib/run-log.sh からの移植)
#
# 背景: meeting-link-sweep は /tmp/meeting-link-sweep-stdout.log に全実行の痕跡を
# 無制限累積し「末尾=直近の実行」という前提が実行時間の間に成り立たなくなった
# (将軍がこの累積ログの末尾を読んで誤診した実例あり)。本リポジトリの定期ジョブ
# (console_stall_watchdog.sh・n8n_inbox_relay.sh 等)にも同型の欠陥がありうるため、
# 同じ規約をこちらにも移植する(automation repo と多重管理になるが、両repoが
# 独立に動く以上、共通ライブラリを1箇所にまとめるより「各repo内で完結する」ことを
# 優先する——cross-repo source は運用上の依存を増やすため避ける)。
#
# 提供関数は automation repo 版と同一シグネチャ:
#   run_log_new_id
#   run_log_start <log_dir> <run_id> <job_name>
#   run_log_end <log_file> <run_id> <start_epoch> <exit_code>
#   run_log_write_last_run <status_file> <run_id> <start_iso> <end_iso> <duration_s> <exit_code> [extra_json]
#   run_log_rotate <log_dir> <keep_n> [archive_dir]
#
# 常に exit 0 (呼出し側ジョブを止めない設計)。

run_log_new_id() {
  echo "$(date '+%Y%m%dT%H%M%S')-$$-${RANDOM}"
}

run_log_start() {
  local log_dir="$1"
  local run_id="$2"
  local job_name="${3:-run}"
  mkdir -p "${log_dir}"
  local log_file="${log_dir}/${job_name}-${run_id}.log"
  echo "=== RUN ${run_id} START $(date '+%Y-%m-%d %H:%M:%S') ===" > "${log_file}"
  echo "${log_file}"
}

run_log_end() {
  local log_file="$1"
  local run_id="$2"
  local start_epoch="$3"
  local exit_code="$4"
  local end_epoch duration
  end_epoch="$(date '+%s')"
  duration=$(( end_epoch - start_epoch ))
  echo "=== RUN ${run_id} END $(date '+%Y-%m-%d %H:%M:%S') duration=${duration}s exit=${exit_code} ===" >> "${log_file}"
  echo "${duration}"
}

run_log_write_last_run() {
  local status_file="$1"
  local run_id="$2"
  local start_iso="$3"
  local end_iso="$4"
  local duration_s="$5"
  local exit_code="$6"
  local extra_json="${7:-}"
  mkdir -p "$(dirname "${status_file}")"
  local tmp_file
  tmp_file="$(mktemp "${status_file}.XXXXXX")"
  {
    printf '{\n'
    printf '  "run_id": "%s",\n' "${run_id}"
    printf '  "start": "%s",\n' "${start_iso}"
    printf '  "end": "%s",\n' "${end_iso}"
    printf '  "duration_s": %s,\n' "${duration_s}"
    printf '  "exit": %s' "${exit_code}"
    if [[ -n "${extra_json}" ]]; then
      printf ',\n  %s\n' "${extra_json}"
    else
      printf '\n'
    fi
    printf '}\n'
  } > "${tmp_file}"
  mv "${tmp_file}" "${status_file}"
}

run_log_rotate() {
  local log_dir="$1"
  local keep_n="$2"
  local archive_dir="${3:-${log_dir}/archive}"
  [[ -d "${log_dir}" ]] || return 0
  (( keep_n < 0 )) && keep_n=0

  local files=()
  while IFS= read -r f; do
    files+=("${f}")
  done < <(find "${log_dir}" -maxdepth 1 -type f -name '*.log' | sort)

  local total=${#files[@]}
  local excess=$(( total - keep_n ))
  if (( excess > 0 )); then
    mkdir -p "${archive_dir}"
    local i
    for (( i=0; i<excess; i++ )); do
      mv "${files[$i]}" "${archive_dir}/"
    done
  fi
  return 0
}
