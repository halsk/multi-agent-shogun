#!/usr/bin/env bash
# lib/mgmt_bloat_thresholds.sh — cmd_766 第四層(ファイルサイズ閾値)の閾値テーブル
#
# 実測(2026-09-06 軍師/将軍実測・queue/reports/gunshi_report.yaml
# measured_current_sizes)に基づく。推測でなく実測値の1.5〜2倍(未超過分: 台帳・
# inbox)・設計指定値(既超過分だった dashboard・tasks・reports は回収後の目標値)を
# 採用している。詳細=queue/reports/gunshi_report.yaml four_layer_design.layer4。
#
# 既に閾値超過中のファイルは、そのまま「超過」として扱う(第二層の週次slim_yamlに
# よる回収が先行する前提だが、回収されるまでの間 超過と正しく報告されるのが仕様——
# 家老/将軍が回収の遅れに気づけるようにするため)。

# 超過の何倍で「大幅超過」(ntfy対象)とみなすか
mgmt_bloat_far_exceed_factor() {
    echo 2
}

# カテゴリ別バイト閾値
mgmt_bloat_threshold_bytes() {
    local category="$1"
    case "$category" in
        ledger)    echo 300000 ;;
        dashboard) echo 100000 ;;
        inbox)     echo 30000 ;;
        tasks)     echo 20000 ;;
        reports)   echo 100000 ;;
        *)         echo 0 ;;
    esac
}

# カテゴリ別の件数閾値 (0 = 件数チェック対象外)
mgmt_bloat_threshold_count() {
    local category="$1"
    case "$category" in
        ledger) echo 40 ;;
        inbox)  echo 20 ;;
        *)      echo 0 ;;
    esac
}

# パスからカテゴリを判定する (対象外なら空文字)
mgmt_bloat_category_for_path() {
    local path="$1"
    case "$path" in
        */shogun_to_karo.yaml)   echo "ledger" ;;
        */dashboard.md)          echo "dashboard" ;;
        */queue/inbox/*.yaml)    echo "inbox" ;;
        */queue/tasks/*.yaml)    echo "tasks" ;;
        */queue/reports/*.yaml)  echo "reports" ;;
        *)                       echo "" ;;
    esac
}

# カテゴリ別の件数計測 (対象外カテゴリは常に0)
mgmt_bloat_count_for_file() {
    local path="$1" category="$2"
    local n
    case "$category" in
        ledger)
            n=$(grep -c '^- id: cmd_' "$path" 2>/dev/null) || n=0
            ;;
        inbox)
            n=$(grep -c '^- content:' "$path" 2>/dev/null) || n=0
            ;;
        *)
            n=0
            ;;
    esac
    echo "$n"
}
