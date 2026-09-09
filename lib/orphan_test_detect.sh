#!/usr/bin/env bash
# lib/orphan_test_detect.sh — cmd_741 第三層①: 「作られたが使われていない」の
# うち orphan test(どのCI jobからも実行されないtestファイル)を検知する
# 純関数ライブラリ。
#
# 背景(原cmd_741の動機・実例④相当): 「e2e/tenants-crud.spec.tsがどのCI job
# でも一度も実行されていなかった(足軽が偶然発見)」。本リポで同型の実例を
# 実測確認済み(subtask_741_layer3_orphan_detection着手時・2026-09-09):
#   - tests/watcher/test_modal_and_idle.bats: .github/workflows/test.yml も
#     Makefile も「tests/*.bats」「tests/unit/」「tests/agent_selfwatch.bats」
#     しか回さず、tests/watcher/ 配下は一切参照されない(cmd_558のPRで追加
#     されて以来、CIで一度も実行されていない)
#   - tests/test_stall_watchdog.sh・tests/test_console_stall_watchdog.sh・
#     tests/test_claude_usage_report.py: いずれも手動実行前提の自作テスト
#     スイート(bats形式でない)で、CI/Makefileのどちらにも組み込まれていない
#
# 設計方針(静的grep・task指示どおり): .github/workflows/*.ymlの本文から
# "tests/..." で始まるパストークンを字句として拾う(bats呼び出しが変数
# 経由でも、その変数を組み立てるコマンド自体に元パターンがリテラルで
# 現れるため——例: ROOT_TESTS=$(ls tests/*.bats ... | grep -v
# 'tests/agent_selfwatch.bats') は変数経由の実行だが "tests/*.bats" と
# "tests/agent_selfwatch.bats" の2トークンがファイル本文にリテラルで
# 存在するため字句抽出で正しく拾える)。取得したパターン集合に対し、
# 実在するtestファイル一覧を突合し、いずれのパターンにも一致しない
# ものをorphanとする。
#
# ★狼少年対策(誤検知が出やすい条件の除外・task④必須要件):
#   1. 「testファイル」の定義を絞る: *.bats、または test_*.sh / test_*.py
#      (basenameが"test_"始まり)に限定する。tests/配下には
#      bloom_classification_accuracy.sh・dim_d_quality_comparison.sh の
#      ような「合否判定つき実験・比較スクリプト」も置かれているが、
#      これらはbats形式の回帰テストではなく手動実行前提の測定ツールで
#      あり(実際に確認済み: ヘッダに「Usage: bash tests/xxx.sh」とあり
#      pass/fail閾値でなく比較実験の体裁)、CIに乗らないこと自体が仕様
#      であり誤検知としてはならない。"test_"始まりでないためこの定義で
#      自然に除外される。
#   2. tests/test_helper/ 配下(bats-support・bats-assertのvendor済み
#      submodule)を除外する。これらは*.bats拡張子を持つ大量のファイル
#      (両ライブラリ自身のユニットテスト)を含むが、我々のCIが実行する
#      対象ではなく上流ライブラリの自己テストである。除外しなければ
#      数十件の恒久的な誤検知(=このwatchdogの信頼を損なう狼少年)を
#      生む。
#   3. ディレクトリ参照("tests/unit/"のような末尾スラッシュ表記や
#      "tests/unit"のような裸のディレクトリ名)は、そのディレクトリ直下
#      (再帰しない)を丸ごとカバー対象とする。bats自身が非再帰的に動作
#      する(`bats tests/unit/`はサブディレクトリを読まない)実挙動に
#      合わせた設計であり、過大カバー(サブディレクトリまで誤って
#      「実行されている」扱いにする)を避ける。
#
# 提供関数:
#   extract_covered_test_patterns <workflow_file>
#     → impure(ファイル読み取りのみ・gh api等の外部通信は無し)。
#       workflow_file本文から "tests/..." パストークンを一意に列挙する。
#
#   is_target_test_file <relative_path>
#     → pure。relative_pathが「orphan検知の対象とすべきtestファイル」か
#       どうかを判定する(上記★1・★2の除外条件を適用)。
#
#   path_matches_any_pattern <relative_path> <pattern1> [pattern2 ...]
#     → pure。relative_pathがパターン群のいずれかでカバーされるかを判定。
#       "*"を含むパターンはbash標準glob(スラッシュを跨がない)で照合、
#       それ以外は完全一致またはディレクトリ前方一致で照合する。
#
#   detect_orphan_tests <workflow_file> <tests_dir>
#     → tests_dir配下の対象testファイルのうち、workflow_fileのどの
#       カバレッジパターンにも一致しないものを相対パス("tests/..."形式)
#       で1行1件列挙する。

extract_covered_test_patterns() {
    local workflow_file="$1"
    [[ -f "$workflow_file" ]] || return 0

    grep -oE 'tests/[A-Za-z0-9_./*-]+' "$workflow_file" | sort -u
}

is_target_test_file() {
    local rel_path="$1"

    # ★2: vendor済みsubmodule(bats-support/bats-assert自身のテスト)は
    # 我々の管理対象ではない。
    case "$rel_path" in
        */test_helper/*) return 1 ;;
    esac

    local base="${rel_path##*/}"
    case "$base" in
        *.bats) return 0 ;;
        test_*.sh|test_*.py) return 0 ;;
    esac
    return 1
}

path_matches_any_pattern() {
    local rel_path="$1"
    shift
    local pattern
    local rel_dir rel_base pat_dir pat_base

    # ★重要: bashの `[[ str == pattern ]]` は(実ファイル名展開と異なり)
    # "*" が "/" を跨いでマッチしてしまう(fnmatchにFNM_PATHNAME相当の
    # 制約が無いため)。"tests/*.bats" をそのまま glob 比較に使うと
    # "tests/watcher/x.bats" のようなサブディレクトリのファイルまで
    # 誤って「カバー済み」と判定してしまい、本来検知すべきorphanを
    # 取りこぼす(実際に本ライブラリ実装中にこの誤りを実測で踏んだ)。
    # そこでディレクトリ部分は常に完全一致とし、"*" はファイル名部分
    # のみに限定してglob適用する(★3の非再帰前提を正しく守るため)。
    rel_dir="${rel_path%/*}"
    rel_base="${rel_path##*/}"
    [[ "$rel_dir" == "$rel_path" ]] && rel_dir=""

    for pattern in "$@"; do
        [[ -z "$pattern" ]] && continue
        if [[ "$pattern" == *"*"* ]]; then
            pat_dir="${pattern%/*}"
            pat_base="${pattern##*/}"
            [[ "$pat_dir" == "$pattern" ]] && pat_dir=""
            # shellcheck disable=SC2053
            if [[ "$rel_dir" == "$pat_dir" && "$rel_base" == $pat_base ]]; then
                return 0
            fi
        else
            # ディレクトリ表記("tests/unit"や"tests/unit/")は直下ファイル
            # のみをカバーする(★3・非再帰。bats本体が`-r/--recursive`を
            # 明示しない限りサブディレクトリを読まない実挙動——
            # `bats --help`で実測確認済み——に合わせる)。
            if [[ "$rel_path" == "$pattern" || "$rel_dir" == "${pattern%/}" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

detect_orphan_tests() {
    local workflow_file="$1"
    local tests_dir="$2"

    [[ -d "$tests_dir" ]] || return 0

    local -a patterns=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && patterns+=("$p")
    done < <(extract_covered_test_patterns "$workflow_file")

    local file rel_path
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        rel_path="tests/${file#"$tests_dir"/}"

        is_target_test_file "$rel_path" || continue

        if ! path_matches_any_pattern "$rel_path" "${patterns[@]}"; then
            echo "$rel_path"
        fi
    done < <(find "$tests_dir" -type f | sort)
}
