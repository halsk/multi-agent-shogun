#!/usr/bin/env bash
# lib/model_drift_check.sh — cmd_869: 出直し時のみのalias漂流検知
#
# ★背景: alias(opus/sonnet)はサーバ側でいつ解決先が変わっても家中は気づけない。
# shutsujin_departure.shでshogun/karo/gunshi/gunshi2を明示ID固定した(cmd_869)が、
# 固定した明示ID自体が現在のCLIバージョンで通らなくなる/aliasの現在解決先が
# 固定値と食い違う、という2種の漂流を出直しのたびに検知する。
# ★新規の常駐プロセス・cron・launchdは追加しない——出直しの既存フロー
# (shutsujin_departure.sh)内の1ステップとして呼ばれる想定。
#
# 実測(cmd_869・2026-09-24・repo外/tmp配下で実施・repo内はcache creation token
# を無駄に消費するため厳禁):
#   claude --model opus -p "1+1" --output-format json
#     → JSON の modelUsage オブジェクトのキーが解決後のcanonicalModel名になる
#       (例: {"claude-opus-5-5": {"canonicalModel":"claude-opus-5-5", ...}})
#   claude --model <存在しないID> -p "1+1" --output-format json
#     → is_error:true, api_error_status:404, modelUsage:{}, exit code 1
#
# エージェント → (alias, 固定値) の対応表。alias が空文字("")のエージェントは
# aliasに対応する仕組みが無い(gunshi2=claude-fable-5-1は元々alias経由でなく
# 明示ID固定だった)ため、固定値自体の疎通確認のみ行う。
MODEL_DRIFT_TABLE=(
    "shogun:opus:claude-opus-5-5"
    "karo:sonnet:claude-sonnet-5"
    "gunshi:opus:claude-opus-5-5"
    "gunshi2::claude-fable-5-1"
)

# テスト時にモックへ差し替え可能にする間接口(PATH経由でclaudeそのものを
# 差し替えるのが最も簡単だが、明示変数でも上書きできるようにしておく)。
MODEL_DRIFT_CLAUDE_BIN="${MODEL_DRIFT_CLAUDE_BIN:-claude}"
MODEL_DRIFT_TIMEOUT_SEC="${MODEL_DRIFT_TIMEOUT_SEC:-60}"
# 未指定時は呼び出しの都度repo外の一時dirを作る(★repo内実行のcache creation
# token浪費を避けるため・将軍実測60,418 tokenの実例あり)。テストはこの変数を
# 固定パスへ上書きして検証する。
MODEL_DRIFT_PROBE_DIR="${MODEL_DRIFT_PROBE_DIR:-}"

# _model_drift_probe(model_arg) → stdout: claudeのJSON応答(取得できた分だけ)
# 戻り値: claudeコマンド自体の終了コードをそのまま返す(124=timeout)
_model_drift_probe() {
    local model_arg="$1"
    # MODEL_DRIFT_PROBE_DIR未指定時のみ自前でtmp dirを作る(テストは固定パスを
    # 渡すため、その場合は呼び出し元の管理下にあり、ここで削除してはならない)。
    local probe_dir="$MODEL_DRIFT_PROBE_DIR"
    local self_created=false
    if [ -z "$probe_dir" ]; then
        probe_dir="$(mktemp -d /tmp/model_drift_probe.XXXXXX)"
        self_created=true
    fi
    local rc
    (
        cd "$probe_dir" || exit 90
        timeout "$MODEL_DRIFT_TIMEOUT_SEC" "$MODEL_DRIFT_CLAUDE_BIN" --model "$model_arg" -p "1+1" --output-format json 2>/dev/null
    )
    rc=$?
    # ★自前で作った一時dirは使い捨て——放置すると出直しの都度/tmpにゴミが
    # 溜まる(長期運用での小さな蓄積問題)。呼び出し元指定分は消さない。
    if [ "$self_created" = true ]; then
        rm -rf "$probe_dir"
    fi
    return "$rc"
}

# _model_drift_canonical(json) → modelUsageの先頭キー(=解決後canonicalModel)。
# 取得不能なら空文字。
_model_drift_canonical() {
    local json="$1"
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print('')
    sys.exit(0)
mu = d.get('modelUsage') or {}
keys = list(mu.keys())
print(keys[0] if keys else '')
" "$json" 2>/dev/null
}

# _model_drift_is_error(json) → "true"/"false"。JSONとして解釈できない場合も
# 安全側("true"=異常扱い)へ倒す。
_model_drift_is_error() {
    local json="$1"
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print('true')
    sys.exit(0)
print('true' if d.get('is_error') else 'false')
" "$json" 2>/dev/null
}

# _model_drift_probe_cached(model_arg) → stdout: JSON。呼び出し元(shutsujin_
# departure.sh)は`set -e`前提のため、非0終了しうる_model_drift_probeの結果を
# 単純代入(`x=$(...)`)で受けると script全体がそこで落ちる(★実測で確認済みの
# バグ——is_error/timeoutという★検知したい状況そのものが、検知ロジックへ
# 辿り着く前にスクリプトを異常終了させてしまう)。ifの条件式はerrexit対象外
# という仕様を使い、ここで安全に終了コードを受け取る。
# 併せて同一model_argへの重複呼び出しをキャッシュで避ける(表内でopus/
# claude-opus-5-5 等が複数エージェントに現れるため、素朴に実装すると同じ
# クエリを何度も実行し実APIコストを無駄に増やす)。
declare -gA _MODEL_DRIFT_JSON_CACHE=()
declare -gA _MODEL_DRIFT_RC_CACHE=()
_model_drift_probe_cached() {
    local model_arg="$1"
    if [[ -z "${_MODEL_DRIFT_RC_CACHE[$model_arg]+set}" ]]; then
        local _json _rc
        if _json=$(_model_drift_probe "$model_arg"); then
            _rc=0
        else
            _rc=$?
        fi
        _MODEL_DRIFT_JSON_CACHE["$model_arg"]="$_json"
        _MODEL_DRIFT_RC_CACHE["$model_arg"]="$_rc"
    fi
}

# check_model_drift() → stdout: 検知した問題(1行1件)。空なら異常無し。
# 戻り値: 常に0(出直しフロー自体は止めない)。
check_model_drift() {
    local findings=()
    local entry agent alias fixed
    _MODEL_DRIFT_JSON_CACHE=()
    _MODEL_DRIFT_RC_CACHE=()

    for entry in "${MODEL_DRIFT_TABLE[@]}"; do
        IFS=':' read -r agent alias fixed <<< "$entry"

        # (1) 固定値そのものが現CLIで通るか
        _model_drift_probe_cached "$fixed"
        local fixed_json="${_MODEL_DRIFT_JSON_CACHE[$fixed]}"
        local fixed_rc="${_MODEL_DRIFT_RC_CACHE[$fixed]}"
        if [ "$fixed_rc" -eq 124 ]; then
            findings+=("${agent}: 固定値 ${fixed} の疎通確認がtimeout(${MODEL_DRIFT_TIMEOUT_SEC}s)——現CLIで通らない疑い")
        elif [ -z "$fixed_json" ] || [ "$(_model_drift_is_error "$fixed_json")" = "true" ]; then
            findings+=("${agent}: 固定値 ${fixed} が現CLIで通らない(is_error/空応答)")
        fi

        # (2) aliasの現在解決先と固定値の食い違い(aliasが無いエージェントは対象外)
        if [ -n "$alias" ]; then
            _model_drift_probe_cached "$alias"
            local alias_json="${_MODEL_DRIFT_JSON_CACHE[$alias]}"
            local resolved
            resolved=$(_model_drift_canonical "$alias_json")
            if [ -n "$resolved" ] && [ "$resolved" != "$fixed" ]; then
                findings+=("${agent}: alias ${alias} の解決先が固定値と不一致(固定=${fixed} / 現在解決=${resolved})")
            fi
        fi
    done

    if [ "${#findings[@]}" -gt 0 ]; then
        printf '%s\n' "${findings[@]}"
    fi
    return 0
}
