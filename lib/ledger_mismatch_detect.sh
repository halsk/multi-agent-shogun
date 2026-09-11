#!/usr/bin/env bash
# lib/ledger_mismatch_detect.sh — report done なのに台帳 cmd が pending/in_progress
# のまま残っている「done未遷移」を機械的に検知する純関数ライブラリ
#
# cmd_766 第一層(発生源検知)。本日 cmd_763/764 が実際にこの型だった
# (完了報告済みで台帳が pending のまま残っていた・将軍指摘で是正)。
#
# 提供関数:
#   ledger_cmd_status <ledger_file> <cmd_id>
#     → shogun_to_karo.yaml 内の該当 cmd の status を1行で返す(無ければ空)
#
#   detect_ledger_mismatches <reports_dir> <ledger_file> <threshold_seconds>
#     → 各行 "cmd_id|report_file|ledger_status|age_seconds" で mismatch を列挙
#
# tmux/flock 非依存。単体テスト可能(source して直接呼べる)。

ledger_cmd_status() {
    local ledger_file="$1"
    local cmd_id="$2"
    [[ -f "$ledger_file" ]] || return 0

    awk -v id="$cmd_id" '
        $0 ~ ("^- id: " id "$") { found = 1; next }
        /^- id: / { found = 0 }
        found && /^  status:/ {
            val = $0
            sub(/^  status:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ' "$ledger_file"
}

# report yaml の「最新エントリ」にある "parent_cmd:" / "status:" 等を
# 1行抽出する。列0(フラット型)・2スペース字下げ("report:"配下)の
# どちらの前提にも対応する(cmd_778②やり直しの主眼——旧実装は列0固定で
# ネスト型を常に空文字扱いしていた)。
#
# ★report yaml は agent ごとに実際の書式が割れており(cmd_778②実データ
# 実測)、1ファイルに何十エントリも時系列で追記蓄積されることがある
# (古い形式・新しい形式が混在することも)。「エントリの開始行」を
# ヘッダー行パターンで検出しようとすると、report_to:/report_command:
# のようなありふれたフィールド名がたまたま "report_" で始まるだけで
# 誤ってヘッダー扱いされ、真に最後のエントリより後ろにあるはずの
# status: 等を範囲外に追い出してしまう(実データで実際に踏んだ実例:
# ashigaru2/5の実report yamlでこれによりstatus/parent_cmdが空文字に
# なった)。そこで「エントリ境界を特定してから範囲内を探す」のではなく、
# 単に該当フィールドのファイル内最後の出現行を直接採る(head→tailに
# するだけ)。追記型ログでは同一フィールドの最後の出現 = 最新エントリの
# 値、という前提のほうがヘッダー検出より単純かつ頑健(実7エージェント分
# のreport yamlで実測確認済み)。
#
# ★grep単体+tail -1の "^(  )?status:" は、instructions/gunshi.mdが必須と
# 定めるreportフッター "north_star_alignment:\n  status: aligned|..." の
# ような、エントリ本体でない付随ブロック配下の同名フィールドも無差別に
# 拾ってしまう(cmd_778②follow-up是正——軍師が実データ実行で発見:
# gunshi_report.yamlのtop-level status(done)ではなく、フッターの
# north_star_alignment.status(aligned)を誤取得していた)。
# そこでawkで「列0(インデント無し)の行が現れたら新しいブロックの開始」
# とみなし、それが north_star_alignment: のような既知の付随ブロックなら
# 次の列0行が現れるまでの間は候補から除外する状態機械にした。
# entry本体(列0のフラットfield、または"report:"配下2字下げの旧nested
# 形式)は従来どおり素通りする——除外対象は既知の付随ブロック名のみ。
#
# ★grep単体を "{ ... || true; }" で包んでいた理由(pipefail対策)はawk化に
# より不要になった: awkはフィールド不在でも0で終了するため、呼び出し元
# (stall_watchdog.sh, set -euo pipefail下)のset -e発動を心配しなくてよい。
_lmd_report_field() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || return 0

    awk -v field="$field" '
        /^[^[:space:]]/ {
            in_excluded = ($0 ~ /^north_star_alignment:/) ? 1 : 0
        }
        in_excluded { next }
        $0 ~ "^(  )?" field ":" {
            line = $0
            sub("^(  )?" field ":[[:space:]]*", "", line)
            gsub(/["'"'"']/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            val = line
        }
        END { print val }
    ' "$file"
}

_lmd_file_mtime_epoch() {
    local file="$1"
    # GNU stat の -c を先に試す。逆順(-f を先)にすると、GNU stat上で
    # -f は「フォーマット指定」ではなく「ファイルシステム情報表示」を
    # 意味するため、失敗時にstderr抑制下でもstdoutへ無関係な情報が
    # 漏れ、mtime変数が汚染されて算術式が壊れる(CI macOS実測・
    # GNU coreutilsがPATH先頭に来る環境で顕在化)。BSD stat は -c 失敗時
    # stdoutを一切汚さないため、-c→-fの順にすれば両対応で安全。
    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null
}

detect_ledger_mismatches() {
    local reports_dir="$1"
    local ledger_file="$2"
    local threshold_sec="${3:-21600}"  # デフォルト6時間(gunshi設計の目安)

    [[ -d "$reports_dir" ]] || return 0

    local now
    now=$(date '+%s')

    local f parent_cmd report_status mtime age ledger_status
    for f in "$reports_dir"/*.yaml; do
        [[ -f "$f" ]] || continue

        parent_cmd=$(_lmd_report_field "$f" "parent_cmd")
        report_status=$(_lmd_report_field "$f" "status")

        [[ -z "$parent_cmd" ]] && continue
        [[ "$report_status" != "done" ]] && continue

        mtime=$(_lmd_file_mtime_epoch "$f")
        [[ -z "$mtime" ]] && continue
        age=$(( now - mtime ))
        [[ "$age" -lt "$threshold_sec" ]] && continue

        ledger_status=$(ledger_cmd_status "$ledger_file" "$parent_cmd")
        [[ -z "$ledger_status" ]] && continue
        [[ "$ledger_status" == "done" || "$ledger_status" == "cancelled" ]] && continue

        printf '%s|%s|%s|%s\n' "$parent_cmd" "$f" "$ledger_status" "$age"
    done
}

# ── cmd_766 第一層 相乗り: blocked/blocked_needs_decision なのに blocked_on/
# blocked_reason が空の「status が実態を語っていない」ケースを検知する
# (2026-09-06 同日中に ashigaru4→ashigaru5 で2度実測された欠陥への対応)
#
# 通常の依存待ち(blocked_by あり)は対象外——それは「実態不明」ではなく
# 正常な依存待ちのため誤検知としない。
#
# 提供関数:
#   detect_blocked_reason_gaps <tasks_dir>
#     → queue/tasks/ashigaru*.yaml, gunshi*.yaml を走査し、各行
#       "file_name|status" で gap を列挙

# task: 直下(2スペースインデント)のフィールドを1行抽出する
# (grep が非0で終わってもpipefail経由でset -eを発動させない理由は
# _lmd_report_field と同じ)
_lmd_task_field() {
    local file="$1" field="$2"
    { grep -E "^  ${field}:" "$file" 2>/dev/null || true; } | head -1 \
        | sed -E "s/^  ${field}:[[:space:]]*//" \
        | tr -d '"' | tr -d "'" \
        | sed -E 's/[[:space:]]+$//'
}

detect_blocked_reason_gaps() {
    local tasks_dir="$1"
    [[ -d "$tasks_dir" ]] || return 0

    local f status blocked_by blocked_on blocked_reason
    for f in "$tasks_dir"/ashigaru*.yaml "$tasks_dir"/gunshi*.yaml; do
        [[ -f "$f" ]] || continue

        status=$(_lmd_task_field "$f" "status")
        [[ "$status" == "blocked" || "$status" == "blocked_needs_decision" ]] || continue

        blocked_by=$(_lmd_task_field "$f" "blocked_by")
        [[ -n "$blocked_by" ]] && continue

        blocked_on=$(_lmd_task_field "$f" "blocked_on")
        blocked_reason=$(_lmd_task_field "$f" "blocked_reason")

        if [[ -z "$blocked_on" || -z "$blocked_reason" ]]; then
            printf '%s|%s\n' "${f##*/}" "$status"
        fi
    done
}

# ── cmd_771 fix_c 相乗り: 孤児cmd検知(idle足軽+台帳の未完了cmdが誰にも
# 割り当てられていない状態)。maybe_nudge_idle は agent 自身の assigned
# タスク前提で動くため、台帳に残った未完了cmdが誰の task YAML の
# parent_cmd にも現れない場合に検知漏れとなる(2026-09-06 殿が2度、
# swarmより先に気づいた主犯)。
#
# 提供関数:
#   detect_orphan_cmds <ledger_file> <tasks_dir> [all_ashigaru_idle]
#     → 各行 "cmd_id|status" で孤児cmdを列挙
#
#   孤児判定:
#     ledger status が pending/in_progress かつ
#     (a) どの task YAML の parent_cmd にも現れない(未割当) または
#     (b) 現れているが all_ashigaru_idle=true (全員idleで誰も手を
#         付けていない=割当があっても実質孤児)

# ledger_file の全 "- id: X" エントリを "id|status" で1行ずつ列挙する
_lmd_all_ledger_cmd_statuses() {
    local ledger_file="$1"
    [[ -f "$ledger_file" ]] || return 0

    awk '
        /^- id: / {
            if (id != "") print id "|" status
            id = $0
            sub(/^- id: /, "", id)
            status = ""
            next
        }
        /^  status:/ {
            val = $0
            sub(/^  status:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            status = val
        }
        END { if (id != "") print id "|" status }
    ' "$ledger_file"
}

# tasks_dir 内の全 task YAML の parent_cmd を集合として返す(1行1id)
_lmd_assigned_parent_cmds() {
    local tasks_dir="$1"
    local f
    for f in "$tasks_dir"/ashigaru*.yaml "$tasks_dir"/gunshi*.yaml; do
        [[ -f "$f" ]] || continue
        local pc
        pc=$(_lmd_task_field "$f" "parent_cmd")
        [[ -n "$pc" ]] && printf '%s\n' "$pc"
    done
}

detect_orphan_cmds() {
    local ledger_file="$1"
    local tasks_dir="$2"
    local all_ashigaru_idle="${3:-false}"

    [[ -f "$ledger_file" ]] || return 0

    local assigned_cmds
    assigned_cmds=$(_lmd_assigned_parent_cmds "$tasks_dir")

    local cmd_id status
    while IFS='|' read -r cmd_id status; do
        [[ -z "$cmd_id" ]] && continue
        [[ "$status" == "pending" || "$status" == "in_progress" ]] || continue

        if printf '%s\n' "$assigned_cmds" | grep -qxF "$cmd_id"; then
            # 割当あり → 全員idleの時のみ孤児扱い(実質誰も手を付けていない)
            [[ "$all_ashigaru_idle" == "true" ]] || continue
        fi

        printf '%s|%s\n' "$cmd_id" "$status"
    done < <(_lmd_all_ledger_cmd_statuses "$ledger_file")
}

# ── cmd_778② 相乗り: report・task YAMLの二面食い違い検知(型h) ────────
#
# 殿ご裁可(2026-09-06)。a〜gのように型を列挙して足すやり方は限界に来ている
# ——「report・task YAMLが一致しているか」という一つの不変条件でまだ見ぬ型も
# 拾う。本日 ashigaru6 のreport(status: done)・task YAML(status: assigned)
# が7〜12時間食い違ったまま放置された実例の再発防止。
#
# ★★★cmd_800恒久修正(2026-09-12・家老判断): 当初はinbox通知の有無も
# 判定材料に含む三面照合だったが、scripts/inbox_write.shの上書き防止仕様
# (メッセージ50件上限・超過時は既読30件のみ保持)により、短時間に大量の
# 通知が飛び交うと正しく通知・処理済みのエントリが物理的に押し出されて
# 消える。inbox本体を「通知が届いたか」の証跡として使うこと自体が
# 構造的に無理があった(inboxは作業キューであり永続ログではない)。
# task YAMLのstatusがdone/cancelledであるという事実こそが「karoが報告を
# 確認し処理した」ことの直接証拠であり、それ以外にinbox通知の有無を別途
# チェックする必要は無い。ゆえに判定は以下(a)の一面(task面)のみへ
# 簡素化した。inbox面の算出(_lmd_inbox_has_entry_from_after)自体は
# stall_watchdog.shの表示(参考情報)向けに残す。
#
# 不変条件: report(queue/reports/{agent}_report.yaml)の最新エントリが
# status: done であるなら、
#   (a) 対応する task YAML(queue/tasks/{agent}.yaml)の status も
#       done/cancelled(完了相当)であるべき ← ★これのみがmismatch判定条件
#   (b) 報告先inbox(既定=karo)に、その報告以降の from:{agent} エントリが
#       存在するか(read:true/falseは問わない) ← 参考情報として出力に
#       残すが、消えていてもmismatch判定には使わない(上記理由)
#
# 提供関数:
#   detect_three_way_mismatch <reports_dir> <tasks_dir> <inbox_file> <threshold_seconds>
#     → 各行 "agent|parent_cmd|report_file|task_status|inbox_ok|age_seconds" で
#       mismatch を列挙(inbox_okは参考情報・0/1いずれでも判定には無関係)

# inbox_file 内に、agent からの from: エントリで timestamp が since 以降の
# ものが存在するかを判定する(read:true/falseは問わない=存在すればOK)。
# ISO8601 (YYYY-MM-DDTHH:MM:SS) は文字列比較で時系列順が保たれる前提。
_lmd_inbox_has_entry_from_after() {
    local inbox_file="$1" agent="$2" since_ts="$3"
    [[ -f "$inbox_file" ]] || return 1
    [[ -z "$since_ts" ]] && return 1

    awk -v agent="$agent" -v since="$since_ts" '
        /^- content:/ { from = ""; ts = "" }
        /^  from:/ {
            val = $0
            sub(/^  from:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            from = val
        }
        /^  timestamp:/ {
            val = $0
            sub(/^  timestamp:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            ts = val
            if (from == agent && ts >= since) { found = 1 }
        }
        END { exit (found ? 0 : 1) }
    ' "$inbox_file"
}

detect_three_way_mismatch() {
    local reports_dir="$1"
    local tasks_dir="$2"
    local inbox_file="$3"
    local threshold_sec="${4:-21600}"  # デフォルト6時間(detect_ledger_mismatchesに倣う)

    [[ -d "$reports_dir" ]] || return 0

    local now
    now=$(date '+%s')

    local f agent parent_cmd report_status report_ts mtime age task_status
    local task_ok inbox_ok
    for f in "$reports_dir"/*_report.yaml; do
        [[ -f "$f" ]] || continue

        agent="${f##*/}"
        agent="${agent%_report.yaml}"

        report_status=$(_lmd_report_field "$f" "status")
        [[ "$report_status" != "done" ]] && continue

        parent_cmd=$(_lmd_report_field "$f" "parent_cmd")
        report_ts=$(_lmd_report_field "$f" "timestamp")

        mtime=$(_lmd_file_mtime_epoch "$f")
        [[ -z "$mtime" ]] && continue
        age=$(( now - mtime ))
        [[ "$age" -lt "$threshold_sec" ]] && continue

        task_status=$(_lmd_task_field "$tasks_dir/${agent}.yaml" "status")
        task_ok=0
        [[ "$task_status" == "done" || "$task_status" == "cancelled" ]] && task_ok=1

        inbox_ok=0
        if _lmd_inbox_has_entry_from_after "$inbox_file" "$agent" "$report_ts"; then
            inbox_ok=1
        fi

        # ★cmd_800恒久修正: 判定条件はtask_okのみ。inbox_okは出力に含めて
        # 参考情報として残すが、mismatch判定のゲートには使わない
        # (inbox_write.shの50件上限で正常エントリが物理的に消えうるため)。
        if [[ "$task_ok" -eq 0 ]]; then
            printf '%s|%s|%s|%s|%s|%s\n' "$agent" "$parent_cmd" "$f" "$task_status" "$inbox_ok" "$age"
        fi
    done
}

# ── cmd_778 相乗り: RACE-001(同一ファイルへの複数 task 並行割当)を機械検知 ──────
#
# 将軍ご指摘(2026-09-08)。本日、家老が ashigaru1 と ashigaru7 へ同一ファイル
# (queue/tasks/gunshi2.yaml)に触れうる作業を並行割当した(結果は偶然無害)。
# 将軍裁定=「これも『規律で直すな』の対象。同一ファイルへの並行割当は機械で
# 弾けるはず。cmd_778 の三面照合へ相乗りさせよ。新設するな」。
#
# 設計(なぜこの形か):
#   - 主signal は task YAML の明示フィールド `touches_files:`(2字下げkey+リスト)。
#     家老が起票時に「この task が worktree 外の共有/gitignore ファイルへ書き込む
#     もの」を列挙する。tracked ファイルの編集は git worktree(必須ルール)が
#     branch 分離で守るため、真の RACE 面は queue/・config/・projects/ 等の
#     共有/gitignore ファイルと main tree 直編集である——そこを列挙対象とする。
#   - 自由記述からのパス抽出(案b)は採らない: 全 task YAML の定型文
#     (report_command の `scripts/inbox_write.sh`・target_path のリポジ root 等)が
#     全 task に共通で現れ、overlap 判定が誤検知だらけになるため(将軍も b の
#     誤検知リスクを明記)。
#   - 「書き忘れ」対策(将軍の必須要件)は detect_undeclared_touches_files で、
#     『気をつける』でなく機械で拾う——active task が 2 件以上(=衝突が物理的に
#     起こりうる並行稼働窓)のときに限り、touches_files 未宣言の active task 自体を
#     炙り出す。単独稼働時は衝突不能ゆえ無音(過検知抑制)。
#
# active task = status が assigned / in_progress のもの(done/cancelled/blocked/
# idle 等は「今まさに編集中」ではないため対象外——RACE は同時編集の問題)。
#
# 提供関数:
#   detect_file_collisions <tasks_dir>
#     → 各行 "path|agent1,agent2,..." で、2 つ以上の active task の
#       touches_files に現れるファイルを列挙(衝突)
#   detect_undeclared_touches_files <tasks_dir>
#     → 各行 "agent|status" で、並行稼働(active>=2)中に touches_files を
#       宣言していない active task を列挙(書き忘れ検知)

# 2 字下げの YAML リストフィールド(key: の次行以降の "- item")の各要素を
# 1 行ずつ返す。key より深いインデントの "- " 行を要素とみなし、それ以外の
# 行(次の同/浅インデントの key や列0行)が来たら打ち切る。
_lmd_task_list_field() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || return 0

    awk -v field="$field" '
        $0 ~ "^  " field ":[[:space:]]*$" { cap = 1; next }
        cap {
            if ($0 ~ /^[[:space:]]+-[[:space:]]/) {
                item = $0
                sub(/^[[:space:]]+-[[:space:]]*/, "", item)
                gsub(/["'"'"']/, "", item)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                if (item != "") print item
                next
            }
            cap = 0
        }
    ' "$file"
}

# task YAML の 2 字下げ key が存在するか(値の有無は問わない)。存在=0。
_lmd_task_has_field() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || return 1
    grep -qE "^  ${field}:" "$file"
}

# active(assigned/in_progress)な worker task YAML を列挙する共通ヘルパ。
# 既存の detect_blocked_reason_gaps 等に倣い ashigaru*/gunshi* を対象とする。
_lmd_active_task_files() {
    local tasks_dir="$1"
    local f status
    for f in "$tasks_dir"/ashigaru*.yaml "$tasks_dir"/gunshi*.yaml; do
        [[ -f "$f" ]] || continue
        status=$(_lmd_task_field "$f" "status")
        [[ "$status" == "assigned" || "$status" == "in_progress" ]] || continue
        printf '%s\n' "$f"
    done
}

detect_file_collisions() {
    local tasks_dir="$1"
    [[ -d "$tasks_dir" ]] || return 0

    local f agent p pairs=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        agent="${f##*/}"; agent="${agent%.yaml}"
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            pairs+="${p}"$'\t'"${agent}"$'\n'
        done < <(_lmd_task_list_field "$f" "touches_files")
    done < <(_lmd_active_task_files "$tasks_dir")

    [[ -z "$pairs" ]] && return 0

    printf '%s' "$pairs" | awk -F'\t' '
        NF == 2 {
            path = $1; agent = $2
            key = path SUBSEP agent
            if (!(key in seen)) {
                seen[key] = 1
                count[path]++
                agents[path] = (path in agents) ? agents[path] "," agent : agent
            }
        }
        END {
            for (p in count) if (count[p] >= 2) print p "|" agents[p]
        }
    '
}

detect_undeclared_touches_files() {
    local tasks_dir="$1"
    [[ -d "$tasks_dir" ]] || return 0

    local f active=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        active+=("$f")
    done < <(_lmd_active_task_files "$tasks_dir")

    # 衝突は active >= 2 の並行稼働窓でのみ起こりうる。単独/無稼働は無音。
    [[ "${#active[@]}" -ge 2 ]] || return 0

    local agent status
    for f in "${active[@]}"; do
        _lmd_task_has_field "$f" "touches_files" && continue
        agent="${f##*/}"; agent="${agent%.yaml}"
        status=$(_lmd_task_field "$f" "status")
        printf '%s|%s\n' "$agent" "$status"
    done
}
