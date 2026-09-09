#!/usr/bin/env bash
# lib/report_consumption_detect.sh — cmd_741 第三層②: 「作られたが使われて
# いない」のうちQC判定・reportの死蔵(実例⑤相当)を検知する純関数ライブラリ。
#
# 背景(原cmd_741の動機): 「軍師のsubtask_739のQC判定が2日間死蔵されていた
# (誰も消費していなかった)」。
#
# ★既存の類縁機構との違い(重複させない・二重通知を避けるための切り分け):
#   - detect_ledger_mismatches / detect_three_way_mismatch(lib/ledger_
#     mismatch_detect.sh)は「機械状態の整合性」(report=doneなのに台帳/
#     task/inbox が追随していないか)を見る。report自体は正しく書かれ・
#     正しく家老へ届いていても、その"内容"(QC判定・推奨)を人が実際に
#     顧みたかは判定しない。
#   - 本ライブラリは「dashboard.md(karoが将軍/殿向けに書く一次的な
#     narrative)にreportの識別子が一度でも現れたか」という別の signal を
#     見る。gunshiのQC reportは本来「karoが読んで判断し、dashboard.mdへ
#     要点を書く」までが consumption であり(Report Flow: Gunshi→Karo→
#     dashboard更新)、dashboard.mdへの言及が無いまま長時間経つのは
#     「機械状態は矛盾していないが誰も中身を見ていない」という
#     ledger_mismatch/three_way_mismatchでは拾えない死蔵を意味する。
#
# ★狼少年対策(誤検知が出やすい条件の除外・task④必須要件):
#   1. status: done の report のみを対象とする(作業中のreportに
#      「消費」を求めるのは早すぎる)。
#   2. しきい値(既定24h)未満は無視する——「まだ誰も見ていないだけの
#      新しいreport」を誤検知しない(task④の明示要件)。
#   3. 対象を呼び出し元が glob で明示的に絞れる設計にする(本ライブラリ
#      自体は queue/reports/*.yaml 全件を強制しない)。stall_watchdog.sh
#      側では実例⑤に直接対応する gunshi_report.yaml(QC判定)のみを
#      対象として配線する——ashigaru報告は日常的に大量発生し1件ずつ
#      dashboard.mdへ個別言及される運用ではないため、全件を対象にすると
#      恒常的な誤検知源になる(過剰設計を避けるための意図的な絞り込み)。
#   4. parent_cmd/task_id のいずれも取れない report は突合材料が無いため
#      静かにスキップする(誤検知よりは無音を選ぶ・fail-safe側)。
#
# ★既知の限界(過剰設計を避けるため受容する簡略化・報告に明記):
#   report yaml が「最新1件のみを上書きする」形式(gunshi_report.yaml等)
#   の場合、次のQC taskが実行され report が上書きされた時点で、その直前
#   まで死蔵されていた古い判定の痕跡は消える(=しきい値に達する前に
#   上書きされれば検知されない)。report形式そのものの再設計は本task
#   の射程外。
#
# 提供関数:
#   _rcd_report_field <file> <field>
#     → report yaml内の該当フィールドの最後の出現値を1行返す
#       (lib/ledger_mismatch_detect.sh の _lmd_report_field と同じ設計:
#       north_star_alignment: のような付随ブロック配下の同名フィールドを
#       誤って拾わないようawkで状態機械にしている)。
#
#   _rcd_file_mtime_epoch <file>
#     → ファイルの最終更新epoch秒(GNU stat→BSD stat の順にfallback)。
#
#   report_mentioned_in_dashboard <dashboard_file> <parent_cmd> <task_id>
#     → parent_cmd または task_id のいずれかがdashboard_file本文に
#       1箇所でも現れれば0(consumed)、どちらも現れなければ1を返す。
#
#   detect_unconsumed_reports <reports_dir> <report_glob> <dashboard_file> <threshold_sec>
#     → reports_dir/report_glob に一致する各report yamlについて、
#       status=done かつ経過時間>=threshold_secかつdashboard.mdに一度も
#       言及されていないものを
#       "agent|parent_cmd|task_id|report_file|age_seconds" で列挙する。

_rcd_report_field() {
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

_rcd_file_mtime_epoch() {
    local file="$1"
    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null
}

report_mentioned_in_dashboard() {
    local dashboard_file="$1" parent_cmd="$2" task_id="$3"
    [[ -f "$dashboard_file" ]] || return 1

    if [[ -n "$parent_cmd" ]] && grep -qF -- "$parent_cmd" "$dashboard_file" 2>/dev/null; then
        return 0
    fi
    if [[ -n "$task_id" ]] && grep -qF -- "$task_id" "$dashboard_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_unconsumed_reports() {
    local reports_dir="$1"
    local report_glob="$2"
    local dashboard_file="$3"
    local threshold_sec="${4:-86400}"  # デフォルト24h(task本文の目安どおり)

    [[ -d "$reports_dir" ]] || return 0

    local now
    now=$(date '+%s')

    local f agent parent_cmd task_id report_status mtime age
    for f in "$reports_dir"/$report_glob; do
        [[ -f "$f" ]] || continue

        agent="${f##*/}"
        agent="${agent%_report.yaml}"

        report_status=$(_rcd_report_field "$f" "status")
        [[ "$report_status" != "done" ]] && continue

        parent_cmd=$(_rcd_report_field "$f" "parent_cmd")
        task_id=$(_rcd_report_field "$f" "task_id")
        [[ -z "$parent_cmd" && -z "$task_id" ]] && continue

        mtime=$(_rcd_file_mtime_epoch "$f")
        [[ -z "$mtime" ]] && continue
        age=$(( now - mtime ))
        [[ "$age" -lt "$threshold_sec" ]] && continue

        if report_mentioned_in_dashboard "$dashboard_file" "$parent_cmd" "$task_id"; then
            continue
        fi

        printf '%s|%s|%s|%s|%s\n' "$agent" "$parent_cmd" "$task_id" "$f" "$age"
    done
}
