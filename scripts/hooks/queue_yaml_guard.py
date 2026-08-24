#!/usr/bin/env python3
"""queue_yaml_guard.py — Claude Code PostToolUse(Edit|Write) hook。

queue/*.yaml (task queue の一次データ) への書込直後に、構文崩れ・重複キー・
`- id:` 境界マーカー件数の減少 (=リスト項目の統合事故) を検知する。

★安全要件(殿ご下命 cmd_742・最重要): queue/shogun_to_karo.yaml は
是正作業(cmd_731)完了まで既に構文エラーを含みうる(約1.1MB)。
本hookは「不正なら常に警告/exit 2」という設計を採らない——それでは
既存の不正ファイルへの編集全てが警告まみれになり、家中がその都度
「直せ」という雑音に晒され続ける(実質的な足止め=デッドロックと同じ害)。

デッドロック不可能性(構造上の裏付け・将軍実測 2026-08-24):
  Claude Code の公式リファレンス(code.claude.com/docs/en/hooks.md
  「Exit code 2 behavior per event」表)によれば、PostToolUse は
  「Can block? No — Shows stderr to Claude; the tool already ran」。
  つまり PostToolUse hook は exit 2 であっても書込を取り消せない
  (ツールは既に実行済)。ゆえに本hookがどう転んでも「書込がブロック
  されてswarmが止まる」という事態はそもそも起こり得ない
  (PreToolUse とは異なる)。

  ただし「機構的にブロックできない」ことと「運用上の足止め」は別問題。
  既に壊れているファイルへ触るたび exit 2 の stderr が Claude に
  フィードバックされ続ければ、無関係な作業のたびに「直せ」と促され、
  本来のタスクが進まなくなる(ソフトなデッドロック)。これを避けるため、
  本hookは状態遷移方式を採る:
    - 直前の観測が既に invalid だった場合、今回も invalid なら
      「今回の編集が原因ではない」とみなし、警告を出さず exit 0 で
      静かに通す(cmd_731完了を待つ、が正しい振る舞い)。
    - 直前の観測が valid で今回 invalid に転じた場合のみ、
      「この編集が壊した可能性が高い」として exit 2 で知らせる。
  `- id:` 境界マーカー件数についても同じ思想: 前回より減っていれば
  知らせるが、既に少ない状態が続いているだけなら黙る。

fail-open 原則: 本hook自身が予期せぬ例外を起こしても exit 0 とする。
安全網自身のバグで agent の作業を妨げてはならない。
"""
import json
import os
import re
import sys
import traceback

try:
    import fcntl
except ImportError:
    fcntl = None  # Windows等 fcntl 非対応環境では無施錠にフォールバック(fail-open)

try:
    import yaml
except ImportError:
    # PyYAML が無い環境では判定不能。fail-open で通す。
    sys.exit(0)

ID_MARKER_RE = re.compile(r"^- id:\s*\S", re.MULTILINE)


class _DuplicateKeyError(Exception):
    pass


class _StrictSafeLoader(yaml.SafeLoader):
    """重複キーを検知する SafeLoader。

    家老が本日3回起こした事故(`- id:` マーカー削除によりリスト2項目が
    1つのマッピングへ統合され、`id:` 等のキーが重複する)は、PyYAML の
    既定動作(重複キーは黙って後勝ちで上書き)では検知できない。
    construct_mapping を override し、重複キーで例外を投げる。
    """

    def construct_mapping(self, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise _DuplicateKeyError(f"duplicate key: {key!r}")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def _validate(text):
    """(is_valid, detail) を返す。例外は握りつぶさず detail に記録する。"""
    try:
        yaml.load(text, Loader=_StrictSafeLoader)
        return True, ""
    except _DuplicateKeyError as e:
        return False, f"duplicate-key: {e}"
    except yaml.YAMLError as e:
        return False, f"yaml-syntax: {e}"


def _project_root():
    # CLAUDE_PROJECT_DIR (公式ドキュメント記載の hook 用環境変数) を最優先。
    # 無ければ hook 自身のリポジトリルートへフォールバック。
    root = os.environ.get("CLAUDE_PROJECT_DIR")
    if not root:
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return root


def _state_path():
    state_dir = os.path.join(_project_root(), ".claude", "hook_state")
    return os.path.join(state_dir, "queue_yaml_guard_state.json")


def _update_state(file_path, new_entry):
    """state ファイルを排他ロック下で読取→更新→書込する(read-modify-write)。

    複数の Edit/Write が短時間に連続発火した場合、ロック無しでは
    「A読込→B読込→A書込→B書込」の順でAの更新が消える競合がありうる
    (swarm はまさに並列tool呼び出しが日常的に起こる環境)。fcntl.flock で
    直列化し、この読み損ないを防ぐ。戻り値は更新前の prev エントリ。
    """
    path = _state_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # 追記可能な既存ファイルを開く(初回は空ファイルを作成)。ロック取得後に
    # 中身を読むことで、他プロセスの書込完了後の最新状態を確実に見る。
    with open(path, "a+", encoding="utf-8") as f:
        if fcntl is not None:
            fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.seek(0)
            raw = f.read()
            try:
                state = json.loads(raw) if raw else {}
            except ValueError:
                state = {}
            prev = state.get(file_path)
            state[file_path] = new_entry
            f.seek(0)
            f.truncate()
            f.write(json.dumps(state))
            f.flush()
            os.fsync(f.fileno())
            return prev
        finally:
            if fcntl is not None:
                fcntl.flock(f, fcntl.LOCK_UN)


def _is_target_file(file_path):
    if not file_path:
        return False
    if not (file_path.endswith(".yaml") or file_path.endswith(".yml")):
        return False
    root = os.path.normpath(_project_root())
    queue_prefix = os.path.join(root, "queue") + os.sep
    normalized = os.path.normpath(file_path)
    return normalized.startswith(queue_prefix)


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw else {}
    except ValueError:
        sys.exit(0)  # 入力契約が予期せぬ形でも fail-open

    tool_name = payload.get("tool_name", "")
    if tool_name not in ("Edit", "Write"):
        sys.exit(0)

    tool_response = payload.get("tool_response")
    if isinstance(tool_response, dict) and tool_response.get("success") is False:
        sys.exit(0)  # 書込自体が失敗しているなら検査不要

    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
    if not _is_target_file(file_path):
        sys.exit(0)

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        sys.exit(0)  # 読めない = 検査不能。fail-open

    is_valid, detail = _validate(text)
    marker_count = len(ID_MARKER_RE.findall(text))

    try:
        prev = _update_state(file_path, {"valid": is_valid, "marker_count": marker_count})
    except OSError:
        sys.exit(0)  # 状態保存の失敗は致命ではない。今回は比較なしで通す(fail-open)。

    if prev is None:
        # 初回観測。比較対象が無いので静かに記録のみ。
        sys.exit(0)

    messages = []
    if prev.get("valid") and not is_valid:
        messages.append(
            f"queue_yaml_guard: {file_path} が今回の編集でYAML構文エラーに"
            f"転じた可能性があります({detail})。直前の編集内容を確認してください。"
        )
    if prev.get("marker_count", 0) > marker_count:
        messages.append(
            f"queue_yaml_guard: {file_path} の `- id:` 境界マーカー数が"
            f"{prev.get('marker_count')}→{marker_count} に減少しました。"
            f"リスト項目が誤って統合されていないか確認してください。"
        )

    if messages:
        print("\n".join(messages), file=sys.stderr)
        sys.exit(2)  # PostToolUse は書込を取り消せない。stderr が Claude への警告として届くのみ。

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # fail-open: 本hook自身のバグで agent の作業を妨げない。
        traceback.print_exc(file=sys.stderr)
        sys.exit(0)
