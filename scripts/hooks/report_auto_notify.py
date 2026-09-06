#!/usr/bin/env python3
"""report_auto_notify.py — Claude Code PostToolUse(Edit|Write) hook。

cmd_778①(殿ご裁可 2026-09-06)。queue/reports/{agent}_report.yaml への
書込で status が新たに "done" へ遷移したことを検知し、
scripts/inbox_write.sh を自動発火して家老(または既定の宛先)へ
report_received を送る。

★★★真因(cmd_778 context): 現行Report Flowは「report YAML書込」+
「inbox_write.sh 実行」の★二手★を各エージェント自身に求めており、
二手を要求する設計はいつか片方が抜ける(ashigaru6が10:49に
status:doneを書いたが2手目が打たれず7時間通知が届かなかった実例)。
本hookは二手目を構造で肩代わりする。

設計方針(queue_yaml_guard.py と同型):
  - fail-open: 本hook自身の検知ロジック(YAML解析・status/agent抽出)
    が失敗しても agent の作業を妨げない(exit 0)。
  - ただし「通知を送ると決めた後にinbox_write.shの起動自体が失敗した」
    場合は★黙って落ちない★(HC_PING_URL_SWEEP未設定で心拍検知が
    13日間黙って死んでいた実例の教訓)。この場合は exit 2 で
    stderr に詳細を出す — PostToolUse は書込を取り消せないので
    (ツール実行は既に完了済み)、agentへの可視化のみが目的。
  - 二重通知防止: 状態ファイルで「このファイルは既に notified 済み」を
    記録し、status が既に done のまま再編集されても再送しない。
    status が done 以外に変わったら notified フラグをリセットする
    (redoで再度 done になった際は再度通知する)。
  - 宛先解決: queue/tasks/{agent}.yaml の report_to フィールド
    (トップレベルまたは task: 直下、実物調査により両方が実在)を
    最優先する。無ければ既定の Report Flow
    (ashigaru→gunshi, gunshi→karo) にフォールバックする。
    agent が karo の場合は「karo→shogunはdashboard経由のみ・
    inbox禁止」という既存ルールに従い、常にスキップする
    (これは失敗ではなく既定の仕様)。
"""
import json
import os
import re
import subprocess
import sys
import traceback

try:
    import fcntl
except ImportError:
    fcntl = None  # Windows等 fcntl 非対応環境では無施錠にフォールバック(fail-open)

try:
    import yaml
except ImportError:
    sys.exit(0)  # PyYAML が無い環境では判定不能。fail-open で通す。

REPORT_FILENAME_RE = re.compile(r"^([A-Za-z0-9_]+)_report\.ya?ml$")

# karo は既存ルール(Karo→Shogun/Lord はdashboard.md更新のみ・
# inbox to shogun禁止)に従い、常にauto-notifyをスキップする印。
_SKIP_KARO = object()


def _project_root():
    root = os.environ.get("CLAUDE_PROJECT_DIR")
    if not root:
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return root


def _state_path():
    state_dir = os.path.join(_project_root(), ".claude", "hook_state")
    return os.path.join(state_dir, "report_auto_notify_state.json")


def _with_state_lock(mutator):
    """状態ファイルを排他ロック下で読み、mutator(state)の戻り値で上書き保存する。

    mutator は現在の state dict を受け取り、(戻したい値, 新しいstate dict) を返す。
    読み取り専用にしたい場合は新しいstate dictとして同じオブジェクトを返せばよい。
    """
    path = _state_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
            result, new_state = mutator(state)
            if new_state is not state:
                f.seek(0)
                f.truncate()
                f.write(json.dumps(new_state))
                f.flush()
                os.fsync(f.fileno())
            return result
        finally:
            if fcntl is not None:
                fcntl.flock(f, fcntl.LOCK_UN)


def _peek_notified(file_path):
    """notifiedフラグを読むだけ(更新しない)。ファイル未記録ならNone。"""
    def _peek(state):
        entry = state.get(file_path) or {}
        return entry.get("notified"), state

    return _with_state_lock(_peek)


def _set_notified(file_path, notified):
    """notifiedフラグを更新する。★通知が実際に成功した後にのみ呼ぶこと。

    (発火前にTrueを書いてしまうと、その後inbox_write.shが失敗しても
    「既に通知済み」扱いになり、次回の再試行が黙って握りつぶされる
    ——実測で発見した実バグ。requirement④の趣旨に反するため、成功後にのみ記録する。)
    """
    def _set(state):
        state[file_path] = {"notified": notified}
        return None, state

    _with_state_lock(_set)


def _is_target_report_file(file_path):
    if not file_path:
        return None
    root = os.path.normpath(_project_root())
    reports_prefix = os.path.join(root, "queue", "reports") + os.sep
    normalized = os.path.normpath(file_path)
    if not normalized.startswith(reports_prefix):
        return None
    basename = os.path.basename(normalized)
    m = REPORT_FILENAME_RE.match(basename)
    return m.group(1) if m else None


def _find_key(data, key, depth=4):
    """dataの中からkeyを幅優先・深さ制限つきで探し、最初に見つかった文字列値を返す。

    report YAML はagentごとに構造がまちまち(トップレベル / `report:`直下 /
    `task:`直下 / 任意名のラッパーキー直下)であることを実物調査で確認済み。
    汎用探索にすることで、いずれの構造にも追従する。
    """
    if depth < 0:
        return None
    if isinstance(data, dict):
        if key in data and isinstance(data[key], str):
            return data[key]
        for v in data.values():
            found = _find_key(v, key, depth - 1)
            if found is not None:
                return found
    return None


def _resolve_recipient(agent, project_root):
    if agent == "karo":
        return _SKIP_KARO
    task_yaml_path = os.path.join(project_root, "queue", "tasks", f"{agent}.yaml")
    report_to = None
    try:
        with open(task_yaml_path, "r", encoding="utf-8") as f:
            task_data = yaml.safe_load(f.read())
        report_to = _find_key(task_data, "report_to")
    except (OSError, yaml.YAMLError):
        report_to = None
    if report_to:
        return report_to
    if agent.startswith("ashigaru"):
        return "gunshi"
    if agent.startswith("gunshi"):
        return "karo"
    return None


def _compose_content(agent, data):
    task_id = _find_key(data, "task_id") or "unknown"
    parent_cmd = _find_key(data, "parent_cmd") or "unknown"
    return (
        f"[auto-notify] {agent}のreport(task_id={task_id}, parent_cmd={parent_cmd})"
        f"がstatus:doneに更新された。詳細はqueue/reports/{agent}_report.yamlを確認せよ。"
    )


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

    project_root = _project_root()

    # --- 検知フェーズ(fail-open: このtryブロック内の異常は agent を妨げない) ---
    try:
        agent = _is_target_report_file(file_path)
        if agent is None:
            sys.exit(0)

        with open(file_path, "r", encoding="utf-8") as f:
            text = f.read()
        data = yaml.safe_load(text)
        status = _find_key(data, "status")
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(0)

    if status is None:
        sys.exit(0)  # statusフィールドを持たない報告形式。判定不能につき静かにスキップ。

    is_done = status == "done"

    if not is_done:
        try:
            _set_notified(file_path, False)  # done以外へ遷移。次回done化に備えリセット。
        except OSError:
            pass  # 状態保存の失敗は致命ではない。fail-open。
        sys.exit(0)

    try:
        prev_notified = _peek_notified(file_path)
    except OSError:
        prev_notified = None  # 状態読取の失敗は致命ではない。fail-open(通知は試みる)。

    if prev_notified is True:
        sys.exit(0)  # 既に通知済み。二重通知防止。

    # --- 発火フェーズ(★黙って落ちない: 失敗はexit 2でstderrへ可視化) ---
    recipient = _resolve_recipient(agent, project_root)
    if recipient is _SKIP_KARO:
        sys.exit(0)  # karo→shogunはdashboard経由のみ。既定仕様につき静かにスキップ。
    if recipient is None:
        print(
            f"report_auto_notify: {agent} の宛先(report_to)を解決できず、"
            f"auto-notifyを発火できなかった。queue/tasks/{agent}.yamlのreport_to"
            f"を確認するか、手動でinbox_write.shを実行せよ。",
            file=sys.stderr,
        )
        sys.exit(2)

    content = _compose_content(agent, data)
    inbox_write = os.path.join(project_root, "scripts", "inbox_write.sh")
    try:
        # inbox_write.sh の最悪ケース(flock -w 5 × 3回 + リトライ間sleep 1s×2)は
        # 約17秒に達しうる(実測ではなく同スクリプトのソース読解による見積り)。
        # settings.json側のhook timeoutも合わせて25秒へ引き上げてあるので、
        # ここは20秒(既定でsettings.json側より余裕を持たせる)とする。
        result = subprocess.run(
            ["bash", inbox_write, recipient, content, "report_received", agent],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception as e:
        print(f"report_auto_notify: inbox_write.sh起動自体が失敗した: {e}", file=sys.stderr)
        sys.exit(2)

    if result.returncode != 0:
        print(
            f"report_auto_notify: inbox_write.shがexit {result.returncode}で失敗した。"
            f"stderr={result.stderr.strip()!r} stdout={result.stdout.strip()!r}",
            file=sys.stderr,
        )
        sys.exit(2)  # ★notifiedは書かない。次回のedit時に再試行できるようにする。

    try:
        _set_notified(file_path, True)  # 実際に成功した後にのみ記録する。
    except OSError:
        pass  # 状態保存の失敗は致命ではない(通知自体は成功済み)。fail-open。

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(0)
