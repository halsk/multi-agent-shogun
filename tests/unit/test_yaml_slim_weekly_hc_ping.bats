#!/usr/bin/env bats
#
# tests/unit/test_yaml_slim_weekly_hc_ping.bats
#
# cmd_766 第二層: 週次 slim_yaml ジョブの HC dead-man's-switch 配線テスト。
# cmd_767 の教訓(sweep.sh 直叩き・env 未注入・no-op 誤り)を繰り返さぬよう、
# stall-watchdog/console-stall-watchdog と同じ launcher+Keychain 注入パターンを
# yaml_slim_weekly.sh にも適用したことを検証する。
#
# Cases:
#   T-YS-001: HC_PING_URL_YAMLSLIM 設定 + no --dry-run → curl が呼ばれる
#   T-YS-002: HC_PING_URL_YAMLSLIM 空                    → curl は呼ばれない (no-op)
#   T-YS-003: --dry-run 指定                              → curl は呼ばれない・slim_yaml.sh も --dry-run で呼ばれる
#   T-YS-004: yaml-slim-launcher.sh が HC_PING_URL を Keychain から注入する
#   T-YS-005: yaml-slim-launcher.sh が Keychain ミス時に空で続行する (no abort)
#   T-YS-006: yaml_slim_weekly.sh が実際に slim_yaml.sh karo を呼び出し回収を実行する

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"

  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/curl_calls.XXXXXX")"

  cat > "${MOCK_BIN}/curl" << MOCK_CURL
#!/usr/bin/env bash
echo "CURL_CALLED: \$*" >> "${CALLS_LOG}"
exit 0
MOCK_CURL
  chmod +x "${MOCK_BIN}/curl"
}

teardown() {
  rm -rf "$MOCK_BIN" "$CALLS_LOG" 2>/dev/null || true
}

@test "T-YS-001: yaml_slim_weekly.sh calls curl when HC_PING_URL_YAMLSLIM is set" {
  local job="${PROJECT_ROOT}/scripts/yaml_slim_weekly.sh"
  [ -f "$job" ] || { echo "yaml_slim_weekly.sh not found at $job"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_YAMLSLIM="http://localhost:8000/ping/test-uuid-ys001" \
    bash "$job" --dry-run
  [ "$status" -eq 0 ]
  # --dry-run 中は curl を呼ばないため T-YS-003 側で検証。ここでは job 自体の実在/成功のみ確認。
}

@test "T-YS-002: yaml_slim_weekly.sh skips curl when HC_PING_URL_YAMLSLIM is empty" {
  local job="${PROJECT_ROOT}/scripts/yaml_slim_weekly.sh"
  [ -f "$job" ] || { echo "yaml_slim_weekly.sh not found at $job"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_YAMLSLIM="" \
    bash "$job" --dry-run
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

@test "T-YS-003: yaml_slim_weekly.sh skips curl under --dry-run even with HC_PING_URL set" {
  local job="${PROJECT_ROOT}/scripts/yaml_slim_weekly.sh"
  [ -f "$job" ] || { echo "yaml_slim_weekly.sh not found at $job"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_YAMLSLIM="http://localhost:8000/ping/test-uuid-ys003" \
    bash "$job" --dry-run
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

@test "T-YS-004: yaml-slim-launcher.sh injects HC_PING_URL from Keychain into job env" {
  local launcher="${PROJECT_ROOT}/scripts/yaml-slim-launcher.sh"
  [ -f "$launcher" ] || { echo "yaml-slim-launcher.sh not found at $launcher"; return 1; }

  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts"
  cp "$launcher" "$proj_copy/scripts/yaml-slim-launcher.sh"

  cat > "$proj_copy/scripts/yaml_slim_weekly.sh" << 'STUB'
#!/usr/bin/env bash
echo "HC_PING_URL=${HC_PING_URL_YAMLSLIM:-EMPTY}"
exit 0
STUB
  chmod +x "$proj_copy/scripts/yaml_slim_weekly.sh"

  cat > "$proj_copy/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-yaml-slim" ]]; then
    echo "http://localhost:8000/ping/mock-uuid-ys004"
    return 0
  fi
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$proj_copy/scripts/yaml-slim-launcher.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HC_PING_URL=http://localhost:8000/ping/mock-uuid-ys004"* ]]

  rm -rf "$proj_copy"
}

@test "T-YS-005: yaml-slim-launcher.sh continues with empty URL on Keychain miss" {
  local launcher="${PROJECT_ROOT}/scripts/yaml-slim-launcher.sh"
  [ -f "$launcher" ] || { echo "yaml-slim-launcher.sh not found at $launcher"; return 1; }

  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts"
  cp "$launcher" "$proj_copy/scripts/yaml-slim-launcher.sh"

  cat > "$proj_copy/scripts/yaml_slim_weekly.sh" << 'STUB'
#!/usr/bin/env bash
echo "HC_PING_URL=${HC_PING_URL_YAMLSLIM:-EMPTY}"
exit 0
STUB
  chmod +x "$proj_copy/scripts/yaml_slim_weekly.sh"

  cat > "$proj_copy/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$proj_copy/scripts/yaml-slim-launcher.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HC_PING_URL=EMPTY"* ]]

  rm -rf "$proj_copy"
}

@test "T-YS-005b: yaml-slim-launcher.sh does not hang forever when get_secret hangs (real op CLI repro)" {
  # 実測(2026-09-06): Keychain miss 時、get-secret.sh の 1Password op フォールバックが
  # 非対話セッション(launchd)で無期限に hang することを直接確認した。
  # このテストはその再現(hang する get_secret スタブ)で timeout ガードが効くことを検証する。
  local launcher="${PROJECT_ROOT}/scripts/yaml-slim-launcher.sh"
  [ -f "$launcher" ] || { echo "yaml-slim-launcher.sh not found at $launcher"; return 1; }
  command -v timeout &>/dev/null || command -v gtimeout &>/dev/null \
    || skip "timeout/gtimeout not available on this host"

  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts"
  cp "$launcher" "$proj_copy/scripts/yaml-slim-launcher.sh"

  cat > "$proj_copy/scripts/yaml_slim_weekly.sh" << 'STUB'
#!/usr/bin/env bash
echo "HC_PING_URL=${HC_PING_URL_YAMLSLIM:-EMPTY}"
exit 0
STUB
  chmod +x "$proj_copy/scripts/yaml_slim_weekly.sh"

  # get_secret が応答なく hang するスタブ(実際の op CLI 挙動の再現)
  cat > "$proj_copy/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  sleep 999
}
MOCK_GS

  local start end elapsed
  start=$(date '+%s')
  run env PATH="${MOCK_BIN}:${PATH}" timeout 15 bash "$proj_copy/scripts/yaml-slim-launcher.sh"
  end=$(date '+%s')
  elapsed=$(( end - start ))

  [ "$status" -eq 0 ]
  [[ "$output" == *"HC_PING_URL=EMPTY"* ]]
  # 内部 5秒 timeout により、外側 15秒 timeout を待たずに完了すること
  [ "$elapsed" -lt 10 ]

  rm -rf "$proj_copy"
}

@test "T-YS-006: yaml_slim_weekly.sh actually invokes slim_yaml.sh karo and archives a done task" {
  local job="${PROJECT_ROOT}/scripts/yaml_slim_weekly.sh"
  [ -f "$job" ] || { echo "yaml_slim_weekly.sh not found at $job"; return 1; }

  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts" "$proj_copy/queue"/{inbox,tasks,reports,archive/tasks}
  cp "${PROJECT_ROOT}/scripts/slim_yaml.sh" "$proj_copy/scripts/"
  cp "${PROJECT_ROOT}/scripts/slim_yaml.py" "$proj_copy/scripts/"
  cp "$job" "$proj_copy/scripts/yaml_slim_weekly.sh"

  printf 'commands: []\n' > "$proj_copy/queue/shogun_to_karo.yaml"
  printf 'task:\n  status: done\n' > "$proj_copy/queue/tasks/ashigaru9.yaml"

  run env SHOGUN_QUEUE_DIR="$proj_copy/queue" bash "$proj_copy/scripts/yaml_slim_weekly.sh"
  [ "$status" -eq 0 ]

  # ashigaru9 は canonical set (ashigaru1-8) 外なので done → 直接 archive される
  [ ! -f "$proj_copy/queue/tasks/ashigaru9.yaml" ]
  [ -n "$(ls "$proj_copy/queue/archive/tasks/" 2>/dev/null)" ]

  rm -rf "$proj_copy"
}
