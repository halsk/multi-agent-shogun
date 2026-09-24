#!/usr/bin/env bats
# test_model_drift_check.bats — cmd_869: alias漂流検知(lib/model_drift_check.sh)のユニットテスト
#
# ★「取り違えが取り違えとして現れる」ことを試す(殿6条+将軍5条):
#   is_errorの有無だけでなく、alias解決先と固定値が人工的に食い違う状況を
#   モックで再現し、検知が実際に鳴ることを確認する。

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
