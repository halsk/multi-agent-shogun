#!/usr/bin/env bats
# test_model_drift_check.bats — cmd_869: alias漂流検知(lib/model_drift_check.sh)のユニットテスト
#
# ★「取り違えが取り違えとして現れる」ことを試す(殿6条+将軍5条):
#   is_errorの有無だけでなく、alias解決先と固定値が人工的に食い違う状況を
#   モックで再現し、検知が実際に鳴ることを確認する。
#
# ★subtask_cmd869a2(軍師QC差し戻し是正)で追加したF1〜F3のRED→GREEN対照:
#   F1/F2/F3いずれも本ファイル内のテストで実証(下記参照)。F1は/bin/bash(実機で
#   確認済みのbash 3.2)を明示指定して実際にsourceし、set -e下でexit 2に
#   ならないことを検証する(bats自体はhomebrew版bash4+で動く可能性があるため
#   /bin/bashを明示する)。

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    MOCK_RESPONSES_DIR="${TEST_TMP}/responses"
    mkdir -p "$MOCK_RESPONSES_DIR"

    MOCK_CLAUDE="${TEST_TMP}/mock_claude.sh"
    cat > "$MOCK_CLAUDE" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock claude CLI for model_drift_check tests.
model=""
while [ $# -gt 0 ]; do
    case "$1" in
        --model) model="$2"; shift 2 ;;
        *) shift ;;
    esac
done
safe="$model"
resp_file="${MOCK_RESPONSES_DIR}/${safe}.json"
exit_file="${MOCK_RESPONSES_DIR}/${safe}.exit"
sleep_file="${MOCK_RESPONSES_DIR}/${safe}.sleep"
if [ -f "$sleep_file" ]; then
    sleep "$(cat "$sleep_file")"
fi
if [ -f "$resp_file" ]; then
    cat "$resp_file"
else
    printf '{"is_error":false,"modelUsage":{"%s":{"canonicalModel":"%s"}}}' "$model" "$model"
fi
if [ -f "$exit_file" ]; then
    exit "$(cat "$exit_file")"
fi
exit 0
MOCK_EOF
    chmod +x "$MOCK_CLAUDE"

    PROBE_DIR="${TEST_TMP}/probe"
    mkdir -p "$PROBE_DIR"

    # ★F2是正: get_agent_model()をcli_adapter.sh(python3/settings.yaml依存)へ
    # 実際に触れず、テスト側でモック定義してから model_drift_check.sh をsource
    # する。model_drift_check.sh は「既にget_agent_modelが定義済みなら
    # cli_adapter.shを読み込まない」設計のため、このモックが優先して使われる。
    # ★可変にしておくことで「settings.yamlの値を変えればcheck_model_driftの
    # 検査対象も追随して変わる(=正本が一本化されている)」ことを実証できる。
    MOCK_MODEL_SHOGUN="claude-opus-5-5"
    MOCK_MODEL_KARO="claude-sonnet-5"
    MOCK_MODEL_GUNSHI="claude-opus-5-5"
    MOCK_MODEL_GUNSHI2="claude-fable-5-1"
    get_agent_model() {
        case "$1" in
            shogun)  echo "$MOCK_MODEL_SHOGUN" ;;
            karo)    echo "$MOCK_MODEL_KARO" ;;
            gunshi)  echo "$MOCK_MODEL_GUNSHI" ;;
            gunshi2) echo "$MOCK_MODEL_GUNSHI2" ;;
            *)       echo "" ;;
        esac
    }

    source "${PROJECT_ROOT}/lib/model_drift_check.sh"

    export MOCK_RESPONSES_DIR
    export MODEL_DRIFT_CLAUDE_BIN="$MOCK_CLAUDE"
    export MODEL_DRIFT_PROBE_DIR="$PROBE_DIR"
    export MODEL_DRIFT_TIMEOUT_SEC=5

    # 正常系レスポンス(alias一致・固定値も通る)を既定として全モデル分書いておく。
    # ★aliasの応答は「aliasが今解決する先=固定値のcanonicalModel」を返す
    # (aliasの文字列自体をcanonicalModelとして返すのは誤り——それでは常に
    # 固定値と不一致になり、正常系のはずが誤検知してしまう。実機での
    # 実測(cmd_869)通り、aliasはmodelUsageのキーが解決後の実モデル名になる)。
    _write_response() {
        local query_model="$1"
        local canonical="$2"
        local safe="$query_model"
        printf '{"is_error":false,"modelUsage":{"%s":{"canonicalModel":"%s"}}}' "$canonical" "$canonical" \
            > "${MOCK_RESPONSES_DIR}/${safe}.json"
    }
    # 固定値そのものへの疎通確認(自分自身を返す)
    _write_response "claude-opus-5-5" "claude-opus-5-5"
    _write_response "claude-sonnet-5" "claude-sonnet-5"
    _write_response "claude-fable-5-1" "claude-fable-5-1"
    # aliasの現在解決先(正常系=固定値と一致)
    _write_response "opus" "claude-opus-5-5"
    _write_response "sonnet" "claude-sonnet-5"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "check_model_drift: 全て正常(alias一致・固定値も通る) → 検知なし" {
    run check_model_drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "check_model_drift: aliasの解決先が固定値と食い違う場合を検知する" {
    # opus alias が claude-opus-6(架空の新モデル)へ黙って動いた状況を人工的に再現
    printf '{"is_error":false,"modelUsage":{"claude-opus-6":{"canonicalModel":"claude-opus-6"}}}' \
        > "${MOCK_RESPONSES_DIR}/opus.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" == *"alias opus"* ]]
    [[ "$output" == *"不一致"* ]]
    [[ "$output" == *"claude-opus-6"* ]]
    # gunshiも同じaliasを使うため同様に検知されるはず
    [[ "$output" == *"gunshi:"* ]]
}

@test "check_model_drift: 固定値が現CLIで通らない場合(is_error)を検知する" {
    # karoの固定値 claude-sonnet-5 が現CLIで通らなくなった状況を人工的に再現
    printf '{"is_error":true,"api_error_status":404,"modelUsage":{}}' \
        > "${MOCK_RESPONSES_DIR}/claude-sonnet-5.json"
    echo 1 > "${MOCK_RESPONSES_DIR}/claude-sonnet-5.exit"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"karo"* ]]
    [[ "$output" == *"claude-sonnet-5"* ]]
    [[ "$output" == *"現CLIで通らない"* ]]
}

@test "check_model_drift: 固定値probeがtimeoutした場合も検知する" {
    export MODEL_DRIFT_TIMEOUT_SEC=1
    echo 3 > "${MOCK_RESPONSES_DIR}/claude-fable-5-1.sleep"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"gunshi2"* ]]
    [[ "$output" == *"timeout"* ]]
}

@test "check_model_drift: aliasが無いエージェント(gunshi2)はmismatch検知の対象外" {
    # gunshi2にはaliasが無い(テーブル上alias=空文字)ため、固定値のcanonicalModel
    # 自体が想定と違う値を返してもmismatch("不一致")としては検知されない
    # (aliasが存在しない以上、比較対象自体が無いため仕様どおり)。
    printf '{"is_error":false,"modelUsage":{"something-else":{"canonicalModel":"something-else"}}}' \
        > "${MOCK_RESPONSES_DIR}/claude-fable-5-1.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" != *"gunshi2"*"不一致"* ]]
}

# ─────────────────────────────────────────────────────────────────
# F2是正: MODEL_DRIFT_TABLEが固定IDを直書きしていないことの実証
# ─────────────────────────────────────────────────────────────────

@test "F2: MODEL_DRIFT_TABLEの各エントリはagent:aliasの2フィールドのみ(固定ID直書きなし)" {
    local entry agent alias extra
    for entry in "${MODEL_DRIFT_TABLE[@]}"; do
        IFS=':' read -r agent alias extra <<< "$entry"
        # 3フィールド目(固定ID)が存在しないこと(直書き廃止の実証)
        [ -z "$extra" ]
    done
}

@test "F2: get_agent_model()の戻り値を変えるとcheck_model_driftの検査対象が追随する(正本一本化の実証)" {
    # RED相当の対照: 旧実装は固定IDを表に直書きしていたため、get_agent_model
    # の戻り値をどう変えても検査対象は変わらなかった(表の値が常に優先された)。
    # ★是正後: settings.yaml相当の値(ここではモック関数)を変えれば、
    # 検査対象がその新しい値に追随することを実証する。
    MOCK_MODEL_KARO="claude-sonnet-9-drifted"
    _write_response "claude-sonnet-9-drifted" "claude-sonnet-9-drifted"
    # aliasは変わらずclaude-sonnet-5を指し続ける状況(=固定値だけが動いた)
    printf '{"is_error":false,"modelUsage":{"claude-sonnet-5":{"canonicalModel":"claude-sonnet-5"}}}' \
        > "${MOCK_RESPONSES_DIR}/sonnet.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"karo"* ]]
    [[ "$output" == *"claude-sonnet-9-drifted"* ]]
    [[ "$output" == *"不一致"* ]]
}

# ─────────────────────────────────────────────────────────────────
# F3是正: probe失敗・timeout時の「確認できず」finding(mismatchと区別)
# ─────────────────────────────────────────────────────────────────

@test "F3: aliasのprobeがtimeoutした場合、不一致でなく「確認できず」として明示検知する" {
    export MODEL_DRIFT_TIMEOUT_SEC=1
    echo 3 > "${MOCK_RESPONSES_DIR}/opus.sleep"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" == *"alias opus"* ]]
    [[ "$output" == *"timeout"* ]]
    [[ "$output" == *"解決先を確認できず"* ]]
    # ★RED観点: 「確認できず」と「不一致」は別物であり、確認不能な状況を
    # 誤って「不一致」と名乗ってはならない
    [[ "$output" != *"shogun"*"不一致"* ]]
}

@test "F3: aliasのprobeがis_errorを返した場合、不一致でなく「確認できず」として明示検知する" {
    printf '{"is_error":true,"api_error_status":500,"modelUsage":{}}' \
        > "${MOCK_RESPONSES_DIR}/opus.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" == *"alias opus"* ]]
    [[ "$output" == *"解決先を確認できず"* ]]
    [[ "$output" != *"shogun"*"不一致"* ]]
}

@test "F3: aliasの応答にmodelUsageが空でcanonicalが取得できない場合も「確認できず」を明示する" {
    # is_error:false だが modelUsage が空(旧実装ならresolvedが空文字になり
    # 「resolvedが空なら比較しない」で無音のまま素通りしていた状況)
    printf '{"is_error":false,"modelUsage":{}}' \
        > "${MOCK_RESPONSES_DIR}/opus.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" == *"alias opus"* ]]
    [[ "$output" == *"解決先を確認できず"* ]]
    [[ "$output" != *"shogun"*"不一致"* ]]
}

@test "F3: karoのmismatch検知には「足軽1〜7も同じalias」の一文が添えられる" {
    printf '{"is_error":false,"modelUsage":{"claude-sonnet-6":{"canonicalModel":"claude-sonnet-6"}}}' \
        > "${MOCK_RESPONSES_DIR}/sonnet.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"karo"* ]]
    [[ "$output" == *"不一致"* ]]
    [[ "$output" == *"足軽1〜7"* ]]
}

@test "F3: shogun/gunshiのmismatch検知には足軽1〜7の一文は付かない(karo限定であることの実証)" {
    printf '{"is_error":false,"modelUsage":{"claude-opus-6":{"canonicalModel":"claude-opus-6"}}}' \
        > "${MOCK_RESPONSES_DIR}/opus.json"

    run check_model_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" != *"足軽1〜7"* ]]
}

# ─────────────────────────────────────────────────────────────────
# F1是正: bash 3.2(declare -A/-gA非対応)でのRED→GREEN実測
# ─────────────────────────────────────────────────────────────────
#
# ★実機(macOS標準/bin/bash)で確認済み: `GNU bash, version 3.2.57`。
# declare -A/-gAはbash 4以降専用の機能であり、bash 3.2ではdeclare自体が
# "invalid option"でexit 2を返す。これがshutsujin_departure.shのように
# `set -e`が有効な文脈でsourceされると、そこでスクリプト全体が停止する
# (このRED/GREEN自体もset -e下で実行し、実際の呼出し文脈を再現する)。

@test "F1 RED: 連想配列(declare -gA)はbash 3.2 + set -e下でexit 2により処理を停止させる(退行防止の生きた実証)" {
    # ★これは「旧実装のgit差分」ではなく「declare -gAという構文そのもの」を
    # 対象にした回帰テストである——将来誰かが本ファイルへ連想配列を
    # 再導入すれば、この事実そのものは変わらず、GREEN側のテストが落ちる
    # ことで検知できる(下のGREENテスト参照)。
    run /bin/bash -c 'set -e; declare -gA _TEST_ASSOC=(); echo GOT_HERE'
    [ "$status" -ne 0 ]
    [[ "$output" != *"GOT_HERE"* ]]
}

@test "F1 GREEN: 現行lib/model_drift_check.shはbash 3.2 + set -e下でもexit 0でsourceでき、check_model_driftが定義される" {
    run /bin/bash -c "
set -e
get_agent_model() { echo 'claude-opus-5-5'; }
source '${PROJECT_ROOT}/lib/model_drift_check.sh'
echo GOT_HERE
type check_model_drift >/dev/null 2>&1 && echo FUNC_DEFINED
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GOT_HERE"* ]]
    [[ "$output" == *"FUNC_DEFINED"* ]]
}
