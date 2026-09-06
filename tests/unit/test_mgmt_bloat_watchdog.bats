#!/usr/bin/env bats
#
# tests/unit/test_mgmt_bloat_watchdog.bats
#
# cmd_766 第三層(掃除機自身の監視)+第四層(ファイルサイズ閾値)の統合テスト。
#
# 第四層(check_layer4): 管理ファイルの実サイズが閾値を超えたら dashboard 記録、
#   閾値の2倍(大幅超過)を超えたら ntfy 送信。cooldown で連打を防ぐ。
# 第三層(check_layer3): slim_yaml の last-run.json を見て、「肥大あり且つ
#   archived==0」が K回連続の"別run"に渡って続いたら通知する。単発の変動
#   (1回だけarchived=0)や、同一runへの複数tick(watchdogは5分毎・slim_yamlは
#   週次)では発火しないことを保証する(ヒステリシス)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -f "$PROJECT_ROOT/scripts/mgmt_bloat_watchdog.sh" ] || skip "mgmt_bloat_watchdog.sh not found"
    command -v python3 &>/dev/null || skip "python3 not available"
}

build_tmp_project() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/lib" "$root/queue"/{inbox,tasks,reports,archive,metrics,mgmt_bloat_watchdog}
    cp "$PROJECT_ROOT/scripts/mgmt_bloat_watchdog.sh" "$root/scripts/"
    cp "$PROJECT_ROOT/lib/mgmt_bloat_thresholds.sh" "$root/lib/"

    # ntfy.sh スタブ: 実curl/実設定に触れず、呼び出しを記録するだけ
    cat > "$root/scripts/ntfy.sh" <<'STUB'
#!/usr/bin/env bash
echo "NTFY_CALLED: $*" >> "${NTFY_CALLS_LOG:-/dev/null}"
STUB
    chmod +x "$root/scripts/ntfy.sh"

    cat > "$root/dashboard.md" <<'DASH'
# dashboard

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required - Awaiting Lord's Decision)

(既存の項目はここに続く)
DASH
}

run_watchdog() {
    local root="$1"
    shift
    SHOGUN_PROJECT_ROOT="$root" \
    SHOGUN_QUEUE_DIR="$root/queue" \
    SHOGUN_DASHBOARD_FILE="$root/dashboard.md" \
    NTFY_CALLS_LOG="$root/ntfy_calls.log" \
    bash "$root/scripts/mgmt_bloat_watchdog.sh" "$@"
}

ntfy_call_count() {
    local root="$1"
    [ -f "$root/ntfy_calls.log" ] || { echo 0; return; }
    grep -c "NTFY_CALLED" "$root/ntfy_calls.log" || true
}

dashboard_entry_count() {
    local root="$1" pattern="$2"
    grep -c "$pattern" "$root/dashboard.md" || true
}

write_last_run() {
    # write_last_run <root> <timestamp> <archived_count>
    local root="$1" ts="$2" archived="$3"
    cat > "$root/queue/metrics/slim_yaml_last_run.json" <<JSON
{"timestamp": "$ts", "archived_count": $archived, "targets": {}}
JSON
}

# ── 第四層 ────────────────────────────────────────────────────────────────

@test "T-MBW-001: 閾値未満のファイルは dashboard記録もntfyも発火しない" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    printf 'task:\n  status: assigned\n' > "$root/queue/tasks/ashigaru1.yaml"

    run run_watchdog "$root"
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "0" ]
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-002: 閾値超過(threshold以上・2倍未満)は dashboard記録のみ・ntfyは発火しない" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    # tasks閾値=20000B。25000Bのdummyを作る(2倍=40000未満)。
    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*25000))"

    run run_watchdog "$root"
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "1" ]
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-003: 大幅超過(閾値の2倍以上)は dashboard記録+ntfy発火する" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    # tasks閾値=20000B。2倍=40000B超のdummyを作る。
    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*45000))"

    run run_watchdog "$root"
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "1" ]
    [ "$(ntfy_call_count "$root")" = "1" ]

    rm -rf "$root"
}

@test "T-MBW-004: cooldown内の連続tickでは二重通知しない" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*45000))"

    run run_watchdog "$root"
    run run_watchdog "$root"
    run run_watchdog "$root"

    # 3回tickしても、cooldown中はdashboard追記・ntfy送信とも1回のみ。
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "1" ]
    [ "$(ntfy_call_count "$root")" = "1" ]

    rm -rf "$root"
}

# ── 第三層(ヒステリシス) ───────────────────────────────────────────────────

@test "T-MBW-005: 単発の『肥大あり且つarchived=0』では発火しない(1回の変動で誤警報しない)" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    # 肥大あり: reports閾値=100000Bを超えるダミー
    python3 -c "open('$root/queue/reports/ashigaru9_report.yaml','w').write('x'*150000)"
    write_last_run "$root" "2026-09-06T10:00:00+09:00" 0

    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-006: K回連続(既定3回)の『肥大あり且つarchived=0』別runで発火する" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/reports/ashigaru9_report.yaml','w').write('x'*150000)"

    write_last_run "$root" "2026-09-01T10:00:00+09:00" 0
    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "0" ]

    write_last_run "$root" "2026-09-08T10:00:00+09:00" 0
    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "0" ]

    write_last_run "$root" "2026-09-15T10:00:00+09:00" 0
    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "1" ]

    rm -rf "$root"
}

@test "T-MBW-007: 正常run(archived>0)はstreakをリセットする" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/reports/ashigaru9_report.yaml','w').write('x'*150000)"

    write_last_run "$root" "2026-09-01T10:00:00+09:00" 0
    run run_watchdog "$root"
    write_last_run "$root" "2026-09-08T10:00:00+09:00" 0
    run run_watchdog "$root"
    # ここでstreak=2のはず。ここで正常runが挟まる。
    write_last_run "$root" "2026-09-15T10:00:00+09:00" 5
    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "0" ]

    # 次の異常runはstreak=1からの再開になるはず(3回目ではない)。
    write_last_run "$root" "2026-09-22T10:00:00+09:00" 0
    run run_watchdog "$root"
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-008: 同一run(同じtimestamp)への複数tickはstreakを増やさない(watchdogは高頻度・slim_yamlは週次)" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/reports/ashigaru9_report.yaml','w').write('x'*150000)"
    write_last_run "$root" "2026-09-01T10:00:00+09:00" 0

    # 同じrunに対して10回tickしても、streakは1のまま(=発火しない)。
    for _ in $(seq 1 10); do
        run run_watchdog "$root"
    done
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-009: --dry-run では dashboard記録もntfyも発火しない" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*45000))"

    run run_watchdog "$root" --dry-run
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "0" ]
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-009b: --dry-run はcooldown状態を書き換えない(本番へのdry-run実行が以後の本通知を握り潰さないこと)" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*45000))"

    # dry-runを何度呼んでも state.yaml は生成されない(cooldownを汚染しない)。
    run run_watchdog "$root" --dry-run
    run run_watchdog "$root" --dry-run
    [ ! -f "$root/queue/mgmt_bloat_watchdog/state.yaml" ]

    # dry-runの後で実行しても、cooldownに邪魔されず初回どおり通知される。
    run run_watchdog "$root"
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "1" ]
    [ "$(ntfy_call_count "$root")" = "1" ]

    rm -rf "$root"
}

@test "T-MBW-010: last-run.json が無ければ第三層は何もしない(初回・slim_yaml未実行)" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    run run_watchdog "$root"
    [ "$status" -eq 0 ]
    [ "$(ntfy_call_count "$root")" = "0" ]

    rm -rf "$root"
}

@test "T-MBW-011: 実行が重なった場合、後発は何もせずexit 0で退く(flock単一起動)" {
    local root
    root="$(mktemp -d "/tmp/mbw_XXXXXX")"
    build_tmp_project "$root"

    python3 -c "open('$root/queue/tasks/ashigaru4.yaml','w').write('task:\n  status: assigned\n  note: |\n' + ('x'*45000))"

    mkdir -p "$root/queue/mgmt_bloat_watchdog"
    # 先行プロセスが lock を保持しているのを模擬する(watchdog本体と同じ
    # STATE_DIR/.lock を掴んだまま長時間居座らせる)。本体は flock 不在環境
    # では mkdir 方式にフォールバックするので、テスト側も同じ方式で模擬する。
    local using_flock=false
    if command -v flock &>/dev/null; then
        using_flock=true
        exec 8>"$root/queue/mgmt_bloat_watchdog/.lock"
        flock -x 8
    else
        mkdir -p "$root/queue/mgmt_bloat_watchdog/.lock.d"
    fi

    run run_watchdog "$root"
    [ "$status" -eq 0 ]
    [ "$(dashboard_entry_count "$root" "mgmt_bloat_watchdog")" = "0" ]
    [ "$(ntfy_call_count "$root")" = "0" ]

    if $using_flock; then
        flock -u 8
        exec 8>&-
    else
        rmdir "$root/queue/mgmt_bloat_watchdog/.lock.d" 2>/dev/null || true
    fi
    rm -rf "$root"
}
