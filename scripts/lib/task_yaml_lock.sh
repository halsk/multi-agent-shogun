#!/usr/bin/env bash
# scripts/lib/task_yaml_lock.sh — task YAML書換の排他ロック(flock/mkdir両対応)。
#
# macOS(GitHub Actions macos-latest含む)の素の環境にはflockコマンドが標準で
# 入っていない(GNU util-linux由来)。scripts/inbox_write.shが同じ理由で
# mkdirベースのフォールバックを持つ(同ファイル「Cross-platform lock」節)。
# start_task.sh・finish_task.shの両方が同じロック方式を必要とするため、
# 重複させずここへ共通化する。
#
# Usage(source後・呼び出し元シェルのfdテーブルを直接操作するため必ず
# サブシェル化せずに呼ぶこと):
#   TYL_LOCKFILE="$FILE.lock" tyl_acquire_lock "$WAIT_SEC" || exit 1
#   ... critical section ...
#   tyl_release_lock

tyl_acquire_lock() {
  local wait_sec="${1:-5}"
  if command -v flock &>/dev/null; then
    exec 200>"$TYL_LOCKFILE"
    flock -w "$wait_sec" 200
    return $?
  fi
  local lock_dir="${TYL_LOCKFILE}.d"
  local interval="0.1"
  local max_iters
  max_iters=$(awk -v w="$wait_sec" 'BEGIN { v = w / 0.1; printf "%d", (v < 1 ? 1 : v) }')
  local i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep "$interval"
    i=$((i + 1))
    [ "$i" -ge "$max_iters" ] && return 1
  done
  return 0
}

tyl_release_lock() {
  if command -v flock &>/dev/null; then
    exec 200>&- 2>/dev/null || true
    return 0
  fi
  rmdir "${TYL_LOCKFILE}.d" 2>/dev/null
  return 0
}
