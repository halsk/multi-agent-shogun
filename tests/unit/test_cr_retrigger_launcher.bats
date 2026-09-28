#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# tests/unit/test_cr_retrigger_launcher.bats
#
# cr-retrigger-launcher.sh のユニットテスト(cmd_908やり直しF5)。
# 設計: queue/reports/cmd908_ratelimit_retrigger_design.md §11 試験6〜9。
#
# Cases:
#   T-CRL-006: HC ping URLがKeychainに無い → exit 1・投稿(curl)も一切行わない
#   T-CRL-007: テストは偽のget-secret.shだけを読む(本物のKeychainを呼ばない)
#   T-CRL-008: ghが無い → /failを送りexit非0
#   T-CRL-009: 成功時のpingの本文にrunnerとrun_idが載る
#
# Approach: stall-watchdog-launcher.sh の T-HC-004/005 と同じ「temp project copy」
# 方式。launcherはSCRIPT_DIR相対でget-secret.shとcr_retrigger.pyを解決するため、
# 一時ディレクトリへ両方を差し替えて置く。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"

  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/curl_calls.XXXXXX")"

  # 実machineのdateへ委譲する薄いラッパー(RUN_ID生成に要る。dateだけは
  # PATHから隠す対象にしない——gh/timeoutの有無だけを制御したいため)。
  REAL_DATE="$(command -v date)"
  cat > "${MOCK_BIN}/date" << MOCK_DATE
#!/usr/bin/env bash
exec "${REAL_DATE}" "\$@"
MOCK_DATE
  chmod +x "${MOCK_BIN}/date"

  # curlモック: 呼び出し(URLとbody)をファイルに記録して成功終了。
  cat > "${MOCK_BIN}/curl" << MOCK_CURL
#!/usr/bin/env bash
echo "CURL_CALLED: \$*" >> "${CALLS_LOG}"
exit 0
MOCK_CURL
  chmod +x "${MOCK_BIN}/curl"

  # dirnameの薄いラッパー(T-CRL-008はghを隠すためPATHをMOCK_BINだけに絞る。
  # launcherのSCRIPT_DIR算出がdirname(coreutilsの外部バイナリ)を要るため、
  # PATHをMOCK_BINだけに絞る場合でも解決できるようにしておく)。
  REAL_DIRNAME="$(command -v dirname)"
  cat > "${MOCK_BIN}/dirname" << MOCK_DIRNAME
#!/usr/bin/env bash
exec "${REAL_DIRNAME}" "\$@"
MOCK_DIRNAME
  chmod +x "${MOCK_BIN}/dirname"

  # bashへのsymlink: 上のラッパー群のshebang(#!/usr/bin/env bash)自体が、
  # PATHをMOCK_BINだけに絞るテスト(T-CRL-008)でも解決できるようにする
  # (envはその時点のPATHで"bash"を探すため、MOCK_BIN自身にbashが要る)。
  ln -s "$(command -v bash)" "${MOCK_BIN}/bash"
}

teardown() {
  rm -rf "$MOCK_BIN" "$CALLS_LOG" "$PROJ_COPY" 2>/dev/null || true
}

# proj_copy: launcherと差し替え用get-secret.sh/cr_retrigger.pyを置く一時プロジェクト。
_make_proj_copy() {
  local launcher="${PROJECT_ROOT}/scripts/cr-retrigger-launcher.sh"
  [ -f "$launcher" ] || { echo "cr-retrigger-launcher.sh not found at $launcher"; return 1; }

  PROJ_COPY="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$PROJ_COPY/scripts"
  cp "$launcher" "$PROJ_COPY/scripts/cr-retrigger-launcher.sh"

  # スタブcr_retrigger.py: 呼ばれたら即0で終える(python3で実行されるため
  # 実行権限は不要)。
  cat > "$PROJ_COPY/scripts/cr_retrigger.py" << 'STUB'
import sys
print("[stub] cr_retrigger.py invoked")
sys.exit(0)
STUB
}

# ── T-CRL-006: HC ping URLがKeychainに無い → exit 1・curlは一切呼ばれない ──

@test "T-CRL-006: exits 1 and posts nothing when hc-ping-url-cr-retrigger is missing from Keychain" {
  _make_proj_copy

  # mock get-secret.sh: 常に失敗(Keychainミスを模す)
  cat > "$PROJ_COPY/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$PROJ_COPY/scripts/cr-retrigger-launcher.sh"
  local launcher_status="$status" launcher_output="$output"

  [ "$launcher_status" -eq 1 ]
  run ! grep -q "CURL_CALLED" "${CALLS_LOG}"
  [[ "$launcher_output" == *"not found in Keychain"* ]]
}

# ── T-CRL-007: 偽のget-secret.shだけが読まれる(本物のKeychainを呼ばない) ──

@test "T-CRL-007: launcher only reads the injected fake get-secret.sh, never the real Keychain" {
  _make_proj_copy

  # 偽のget-secret.sh: 本物のKeychainには一切触れず、目印の偽URLを返す。
  cat > "$PROJ_COPY/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-cr-retrigger" ]]; then
    echo "http://127.0.0.1:9/mock-ping-url-not-real-keychain"
    return 0
  fi
  return 1
}
MOCK_GS

  # gh/timeoutをMOCK_BINに用意し、python3が実行される所まで進める。
  cat > "${MOCK_BIN}/gh" << 'MOCK_GH'
#!/usr/bin/env bash
exit 0
MOCK_GH
  chmod +x "${MOCK_BIN}/gh"
  REAL_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)"
  cat > "${MOCK_BIN}/timeout" << MOCK_TIMEOUT
#!/usr/bin/env bash
exec "${REAL_TIMEOUT_BIN}" "\$@"
MOCK_TIMEOUT
  chmod +x "${MOCK_BIN}/timeout"

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$PROJ_COPY/scripts/cr-retrigger-launcher.sh"

  [ "$status" -eq 0 ]
  grep -q "mock-ping-url-not-real-keychain" "${CALLS_LOG}"
  # 本物のKeychainキー名(hc-ping-url-cr-retrigger)を扱うget_secretの実体は
  # このテストのfake一つだけであり、本物のop/security呼び出しは行っていない
  # (get-secret.sh自体を差し替えているため、実体を持たない)。
  run ! grep -qE "security find-generic-password|op item get" "${CALLS_LOG}"
}

# ── T-CRL-008: ghが無い → /failを送りexit非0 ──

@test "T-CRL-008: sends /fail and exits non-zero when gh is not on PATH" {
  _make_proj_copy

  cat > "$PROJ_COPY/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-cr-retrigger" ]]; then
    echo "http://127.0.0.1:9/mock-ping-url-008"
    return 0
  fi
  return 1
}
MOCK_GS

  # MOCK_BINにghを置かない(date・curl・dirnameのみ) → command -v gh が失敗する。
  # bash自体は絶対パスで指定する(envのPATH解決対象から外すため。PATHは
  # スクリプト内部のcommand -v gh判定だけを制御する)。
  run env PATH="${MOCK_BIN}" \
    "$(command -v bash)" "$PROJ_COPY/scripts/cr-retrigger-launcher.sh"

  [ "$status" -ne 0 ]
  grep -q "CURL_CALLED.*mock-ping-url-008/fail" "${CALLS_LOG}"
}

# ── T-CRL-009: 成功時のpingの本文にrunnerとrun_idが載る ──

@test "T-CRL-009: successful ping body carries runner=launchd and a run_id" {
  _make_proj_copy

  cat > "$PROJ_COPY/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-cr-retrigger" ]]; then
    echo "http://127.0.0.1:9/mock-ping-url-009"
    return 0
  fi
  return 1
}
MOCK_GS

  cat > "${MOCK_BIN}/gh" << 'MOCK_GH'
#!/usr/bin/env bash
exit 0
MOCK_GH
  chmod +x "${MOCK_BIN}/gh"
  REAL_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)"
  cat > "${MOCK_BIN}/timeout" << MOCK_TIMEOUT
#!/usr/bin/env bash
exec "${REAL_TIMEOUT_BIN}" "\$@"
MOCK_TIMEOUT
  chmod +x "${MOCK_BIN}/timeout"

  # python3自体は実machineのものを使う(スタブcr_retrigger.pyは即0で終える)。
  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$PROJ_COPY/scripts/cr-retrigger-launcher.sh"

  [ "$status" -eq 0 ]
  # /start と 成功pingの両方が呼ばれ、成功pingの本文にrunner=launchdとrun_idが載る。
  grep -q "CURL_CALLED.*mock-ping-url-009/start" "${CALLS_LOG}"
  success_ping_line="$(grep "mock-ping-url-009$" "${CALLS_LOG}")"
  [[ "$success_ping_line" == *"--data"* ]]
  [[ "$success_ping_line" =~ runner=launchd\ run_id=[0-9TZ]+-[0-9]+ ]]
}
