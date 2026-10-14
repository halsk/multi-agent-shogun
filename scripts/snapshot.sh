#!/usr/bin/env bash
# snapshot.sh — 台帳等の定期控え(軍師設計P1/P2)。独立ローカルgitへcommitする。
# 失敗しても異常終了しない(控えの失敗で家中を止めない)。失敗は logs/snapshot_errors.log へ。
# env: SNAPSHOT_SRC(既定=project root) / SNAPSHOT_DEST(既定 ~/workspace/shogun-state-backup)
#      SNAPSHOT_LOG(既定 $SRC/logs/snapshot_errors.log)
# ★本リポ(PUBLIC)のgitには何も入れぬ。DESTはremote無しの別repo。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="${SNAPSHOT_SRC:-$(cd "$SELF_DIR/.." && pwd -P)}"
DEST="${SNAPSHOT_DEST:-$HOME/workspace/shogun-state-backup}"
LOG="${SNAPSHOT_LOG:-$SRC/logs/snapshot_errors.log}"

err() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null; }
bk() { git -C "$DEST" "$@"; }

main() {
  [[ -d "$DEST/.git" ]] || { err "DEST is not a git repo: $DEST (run scripts/snapshot_init.sh)"; return 0; }
  # remoteが付いていたら安全側で中止(公開漏洩防止)
  if [[ -n "$(bk remote 2>/dev/null)" ]]; then err "DEST has a remote; refusing"; return 0; fi

  local files=() f
  for f in queue/shogun_to_karo.yaml dashboard.md config/settings.yaml "$SRC"/queue/tasks/*.yaml "$SRC"/queue/inbox/*.yaml; do
    f="${f#"$SRC"/}"
    [[ -f "$SRC/$f" ]] && files+=("$f")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0

  # 同時実行排除(flock無し環境はmkdir fallback)
  local lock="$DEST/.git/snapshot.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock"; flock -w 8 9 || { err "lock timeout"; return 0; }
  else
    local i=0
    while ! mkdir "$lock.d" 2>/dev/null; do
      sleep 0.1; i=$((i+1)); [[ $i -ge 80 ]] && { err "lock timeout"; return 0; }
    done
    trap 'rmdir "$lock.d" 2>/dev/null' RETURN
  fi

  # YAMLとして読めるか(0バイト=None も壊れ扱い)。壊れたものは名前を列挙
  local broken
  broken="$(cd "$SRC" && python3 -I - "${files[@]}" <<'PY' 2>>"$LOG"
import sys, yaml
L = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
for p in sys.argv[1:]:
    if not p.endswith(".yaml"):
        continue
    try:
        with open(p) as fh:
            d = yaml.load(fh, Loader=L)
        if d is None:
            print(p)
    except Exception:
        print(p)
PY
)" || { err "yaml check failed to run"; broken=""; }

  for f in "${files[@]}"; do
    { mkdir -p "$DEST/$(dirname "$f")" && cp -p "$SRC/$f" "$DEST/$f"; } || err "copy failed: $f"
  done

  bk add -A >/dev/null 2>&1 || { err "add failed"; return 0; }
  if bk diff --cached --quiet 2>/dev/null; then return 0; fi
  local msg="snapshot $(date '+%Y-%m-%dT%H:%M:%S%z')"
  if [[ -n "$broken" ]]; then
    msg="[BROKEN] $msg: $(echo "$broken" | tr '\n' ' ')"
  fi
  bk commit -q --no-verify -m "$msg" >/dev/null 2>>"$LOG" || err "commit failed"
  return 0
}

main "$@" || true
exit 0
