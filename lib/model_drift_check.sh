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
# ★軍師QC是正(cmd_869・subtask_cmd869a2)で判明した3点:
#
# F1(高・blocking): 連想配列(declare -A/-gA)はbash 4以降専用の機能である。
# PATHにhomebrewが無い環境の/bin/bash 3.2(macOS標準)でsourceすると
# `declare: -A: invalid option`でexit 2になり(実測確認済み)、`set -e`下の
# shutsujin_departure.sh STEP 6.4でこれが起きると出陣処理全体がそこで停止する
# (STEP 6.5以降の指示書読み込み等が走らない)。CI環境は通常bash4+のため
# 再現しない。★是正: 連想配列を一切使わず、並行インデックス配列+線形探索の
# キャッシュへ置き換えた(下記_MODEL_DRIFT_CACHE_*)。
#
# F2(中・blocking): MODEL_DRIFT_TABLEに固定IDを直書きしていたのを廃した。
# 直書きだと正本がsettings.yaml・本表の2か所に分裂し、settings.yamlだけを
# 更新した場合に「実際に起動するID」でなく「表に書いた古い値」を検査して
# しまう。★是正: 固定値はlib/cli_adapter.shのget_agent_model()から都度読む。
# 本表にはagent:aliasのみを持たせる(aliasが無いエージェントは空文字)。
#
# F3(中・blocking): aliasのprobeが失敗・timeoutすると解決先(resolved)が
# 空文字になり、旧実装は「resolvedが空なら比較自体をしない」という設計の
# ため、mismatch判定が★無音で素通りしていた(確認不能な状態と、確認して
# 一致していた状態とが区別できなかった)。★是正: probe失敗・timeout・
# 応答からcanonicalModelを取得できない場合はそれぞれ「解決先を確認できず」
# という★別種の finding を明示出力する(mismatchとは文言・原因を区別)。
# ★併せて、karo(sonnet)のmismatch検知メッセージには「足軽1〜7も同じalias」
# の一文を添える——karoのalias sonnetが漂流すれば足軽1〜7(cli_adapter既定
# =sonnet)の漂流も意味するため。
#
# F4(情報・訂正): 旧reportで「呼び出し元がset -e前提のため、未ガードの
# 代入を直接呼ぶとscript全体が落ちる重大バグ」と書いたのは誇張だった。
# ★実測(このtask内・/tmp/errexit_test.sh相当のスクリプトで確認):
# 実際の呼出し口は shutsujin_departure.sh の `_model_drift_findings=$(check_model_drift)`
# という★コマンド置換経由であり、この形では関数内部の未ガード代入
# (`x=$(cmd)`でcmdが非0終了)があっても、内側のsubshellでもouter scriptでも
# errexitは発火せず処理が継続する(コマンド置換で生成されるsubshell内の
# 失敗は、その代入が「単純コマンドとして直接テストされる」文脈でない限り
# 上位のerrexitへ伝播しない、というbashの既知の挙動)。★check_model_drift
# を将来どこかで直接呼ぶ経路(command substitution を介さない形)に変えた
# 場合は挙動が変わりうるため、ifの条件式での安全な受け取りは防御として
# 引き続き維持する(誤りではなく、有効な多層防御)。
#
# F5(情報・任意・未対応): probe5つ・各timeout60秒を毎回順に走らせると
# 最悪5分の遅延になり得る、との軍師所見。★本taskでは対応しない
# (時間的制約・スコープ外と判断)。対応するなら並列化またはprobe自体の
# 削減が候補になる——別taskで検討されたい。
MODEL_DRIFT_TABLE=(
    "shogun:opus"
    "karo:sonnet"
    "gunshi:opus"
    "gunshi2:"
)

# get_agent_model()はlib/cli_adapter.shが提供する。既に(テストのモック等で)
# 定義済みならそれを使い、無ければ本体を読み込む——テストはcli_adapter.shの
# python3依存を避けるため、get_agent_modelを自前でモック定義してから本
# ファイルをsourceする想定(下記関数一覧コメント参照)。
if ! declare -f get_agent_model >/dev/null 2>&1; then
    MODEL_DRIFT_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/cli_adapter.sh
    source "${MODEL_DRIFT_CHECK_DIR}/cli_adapter.sh"
fi

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

# _model_drift_probe_cached(model_arg) → 結果は _MODEL_DRIFT_LAST_JSON /
# _MODEL_DRIFT_LAST_RC へ格納する(戻り値ではなくグローバル変数経由——
# bash 3.2には連想配列が無く、かつcommand substitutionでの受け渡しは
# 呼び出し元のset -e下で意図せぬ扱いになりうるため、単純代入のみで完結
# させる設計)。
# 同一model_argへの重複呼び出しは並行インデックス配列(_MODEL_DRIFT_CACHE_*)
# による線形探索キャッシュで避ける(表内でopus/claude-opus-5-5等が複数
# エージェントに現れるため、素朴に実装すると同じクエリを何度も実行し
# 実APIコストを無駄に増やす)。エージェント数が小規模(現状4件・alias/固定値
# 合わせても高々8件程度)なので線形探索で十分。
_MODEL_DRIFT_CACHE_KEYS=()
_MODEL_DRIFT_CACHE_JSON=()
_MODEL_DRIFT_CACHE_RC=()
_MODEL_DRIFT_LAST_JSON=""
_MODEL_DRIFT_LAST_RC=""
_model_drift_probe_cached() {
    local model_arg="$1"
    local i
    for ((i = 0; i < ${#_MODEL_DRIFT_CACHE_KEYS[@]}; i++)); do
        if [ "${_MODEL_DRIFT_CACHE_KEYS[$i]}" = "$model_arg" ]; then
            _MODEL_DRIFT_LAST_JSON="${_MODEL_DRIFT_CACHE_JSON[$i]}"
            _MODEL_DRIFT_LAST_RC="${_MODEL_DRIFT_CACHE_RC[$i]}"
            return 0
        fi
    done
    local _json _rc
    if _json=$(_model_drift_probe "$model_arg"); then
        _rc=0
    else
        _rc=$?
    fi
    _MODEL_DRIFT_CACHE_KEYS+=("$model_arg")
    _MODEL_DRIFT_CACHE_JSON+=("$_json")
    _MODEL_DRIFT_CACHE_RC+=("$_rc")
    _MODEL_DRIFT_LAST_JSON="$_json"
    _MODEL_DRIFT_LAST_RC="$_rc"
}

# check_model_drift() → stdout: 検知した問題(1行1件)。空なら異常無し。
# 戻り値: 常に0(出直しフロー自体は止めない)。
check_model_drift() {
    local findings=()
    local entry agent alias fixed
    _MODEL_DRIFT_CACHE_KEYS=()
    _MODEL_DRIFT_CACHE_JSON=()
    _MODEL_DRIFT_CACHE_RC=()

    for entry in "${MODEL_DRIFT_TABLE[@]}"; do
        IFS=':' read -r agent alias <<< "$entry"

        # 固定値は都度get_agent_model()から読む(正本=settings.yaml一本化・F2)。
        fixed=$(get_agent_model "$agent")

        # (1) 固定値そのものが現CLIで通るか
        _model_drift_probe_cached "$fixed"
        local fixed_json="$_MODEL_DRIFT_LAST_JSON"
        local fixed_rc="$_MODEL_DRIFT_LAST_RC"
        if [ "$fixed_rc" -eq 124 ]; then
            findings+=("${agent}: 固定値 ${fixed} の疎通確認がtimeout(${MODEL_DRIFT_TIMEOUT_SEC}s)——現CLIで通らない疑い")
        elif [ -z "$fixed_json" ] || [ "$(_model_drift_is_error "$fixed_json")" = "true" ]; then
            findings+=("${agent}: 固定値 ${fixed} が現CLIで通らない(is_error/空応答)")
        fi

        # (2) aliasの現在解決先と固定値の食い違い(aliasが無いエージェントは対象外)。
        # ★F3: probe失敗・timeout・解決先取得不能は「不一致」とは別種の
        # 「確認できず」finding として明示し、無音で素通りさせない。
        if [ -n "$alias" ]; then
            _model_drift_probe_cached "$alias"
            local alias_json="$_MODEL_DRIFT_LAST_JSON"
            local alias_rc="$_MODEL_DRIFT_LAST_RC"
            if [ "$alias_rc" -eq 124 ]; then
                findings+=("${agent}: alias ${alias} の疎通確認がtimeout(${MODEL_DRIFT_TIMEOUT_SEC}s)——解決先を確認できず")
            elif [ -z "$alias_json" ] || [ "$(_model_drift_is_error "$alias_json")" = "true" ]; then
                findings+=("${agent}: alias ${alias} の疎通確認に失敗(is_error/空応答)——解決先を確認できず")
            else
                local resolved
                resolved=$(_model_drift_canonical "$alias_json")
                if [ -z "$resolved" ]; then
                    findings+=("${agent}: alias ${alias} の応答から解決先を取得できず(modelUsage空)——解決先を確認できず")
                elif [ "$resolved" != "$fixed" ]; then
                    local karo_note=""
                    if [ "$agent" = "karo" ]; then
                        karo_note="(足軽1〜7も同じalias ${alias} を使用——karoの漂流は足軽1〜7の漂流も意味する)"
                    fi
                    findings+=("${agent}: alias ${alias} の解決先が固定値と不一致(固定=${fixed} / 現在解決=${resolved})${karo_note}")
                fi
            fi
        fi
    done

    if [ "${#findings[@]}" -gt 0 ]; then
        printf '%s\n' "${findings[@]}"
    fi
    return 0
}
