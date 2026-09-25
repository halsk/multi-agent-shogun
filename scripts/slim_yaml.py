#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For Karo: Archives completed task/report files and finished command queue entries.
- For all agents: Archives read: true messages from inbox files.
"""

import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import yaml

CANONICAL_TASKS = {f'ashigaru{i}' for i in range(1, 9)} | {'gunshi'}
CANONICAL_REPORTS = {f'ashigaru{i}_report' for i in range(1, 9)} | {'gunshi_report'}
IDLE_STUB = {'task': {'status': 'idle'}}

# 家老起票2026-09-25(subtask_karo_20260925_watchdog_fixes)【二】:
# 正典report YAML内で、書いた本人が既に「これは古い」と自己申告している
# trailerキーの接頭辞。previous_report_*(ashigaru5実例)・old_report_*/
# _old_report_*(ashigaru7実例)。曖昧な形式(ashigaru4/6のような自己申告の
# 無いreport_cmdXXX_*等)は誤って現在有効な内容を退避してしまう危険がある
# ため対象に含めない(安全側に倒す)。
CANONICAL_REPORT_OLD_KEY_PREFIXES = ('previous_report_', 'old_report_', '_old_report_')

# instructions/common/task_flow.md「Canonical statuses」節が正本。
# pending/in_progress は active、done/cancelled/paused は archive対象(terminal)。
LEDGER_CANONICAL_STATUSES = {'pending', 'in_progress', 'done', 'cancelled', 'paused'}
LEDGER_TERMINAL_STATUSES = {'done', 'cancelled', 'paused'}


def load_yaml(filepath):
    """Safely load YAML file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        print(f"Error parsing {filepath}: {e}", file=sys.stderr)
        return {}


def save_yaml(filepath, data):
    """Safely save YAML file."""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        return True
    except Exception as e:
        print(f"Error writing {filepath}: {e}", file=sys.stderr)
        return False


def get_timestamp():
    """Generate archive filename timestamp."""
    return datetime.now().strftime('%Y%m%d%H%M%S')


def get_queue_dir():
    override = os.environ.get('SHOGUN_QUEUE_DIR')
    if override:
        return Path(override).resolve()
    return Path(__file__).resolve().parent.parent / 'queue'


def get_active_cmd_ids():
    """Return command IDs in shogun_to_karo that are not done."""
    queue_dir = get_queue_dir()
    shogun_file = queue_dir / 'shogun_to_karo.yaml'
    data = load_yaml(shogun_file)

    key = 'commands' if 'commands' in data else 'queue'
    commands = data.get(key, []) if isinstance(data, dict) else []
    if not isinstance(commands, list):
        return set()

    active = set()
    for cmd in commands:
        if not isinstance(cmd, dict):
            continue
        if cmd.get('id') is None:
            continue
        if cmd.get('status') == 'done':
            continue
        active.add(cmd.get('id'))
    return active


def ensure_parent_dir(path):
    path.parent.mkdir(parents=True, exist_ok=True)


def file_size_bytes(path):
    """Byte size of a single file, 0 if it doesn't exist."""
    return path.stat().st_size if path.exists() else 0


def dir_size_bytes(path):
    """Sum of byte sizes of top-level files in a directory, 0 if it doesn't exist."""
    if not path.exists():
        return 0
    return sum(p.stat().st_size for p in path.glob('*') if p.is_file())


def write_last_run_metrics(before_sizes, after_sizes, archived_counts):
    """Write cmd_766 layer3 (watch the cleaner) metrics: what this karo sweep
    actually archived, per target. Consumed by scripts/mgmt_bloat_watchdog.sh
    to detect a cleaner that has gone silent (size over threshold, archived=0,
    K consecutive runs)."""
    metrics_dir = get_queue_dir() / 'metrics'
    metrics_dir.mkdir(parents=True, exist_ok=True)
    metrics_file = metrics_dir / 'slim_yaml_last_run.json'

    targets = {}
    total_archived = 0
    for key in ('ledger', 'tasks', 'reports', 'inbox'):
        archived = archived_counts.get(key, 0)
        total_archived += archived
        targets[key] = {
            'before_bytes': before_sizes.get(key, 0),
            'after_bytes': after_sizes.get(key, 0),
            'archived': archived,
        }

    payload = {
        'timestamp': datetime.now().astimezone().isoformat(),
        'archived_count': total_archived,
        'targets': targets,
    }

    with open(metrics_file, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def archive_taskspec(filepath, archive_path, data, dry_run=False):
    if dry_run:
        print(f"[DRY-RUN] would archive: {filepath}")
        print(f"[DRY-RUN] would write: {archive_path}")
        return True

    ensure_parent_dir(archive_path)
    if not save_yaml(archive_path, data):
        return False

    if filepath.name in archive_path.name:
        return True
    return filepath.rename(archive_path)


def slim_tasks(dry_run=False):
    """Returns the number of task files archived, or -1 on error."""
    queue_dir = get_queue_dir()
    tasks_dir = queue_dir / 'tasks'
    archive_dir = queue_dir / 'archive' / 'tasks'

    if not tasks_dir.exists():
        return 0

    timestamp = get_timestamp()
    done_statuses = {'done', 'completed', 'cancelled'}
    archived_count = 0

    for filepath in sorted(tasks_dir.glob('*.yaml')):
        data = load_yaml(filepath)
        if not isinstance(data, dict):
            continue

        task = data.get('task', {}) if isinstance(data.get('task', {}), dict) else {}
        status = task.get('status', '') if isinstance(task, dict) else ''
        if not status:
            continue

        stem = filepath.stem
        if stem in CANONICAL_TASKS:
            if status not in done_statuses:
                continue

            archive_path = archive_dir / f'{stem}_{timestamp}.yaml'
            if not archive_taskspec(filepath, archive_path, data, dry_run=dry_run):
                return -1

            if dry_run:
                print(f"[DRY-RUN] would overwrite: {filepath} with {IDLE_STUB}")
                continue

            if not save_yaml(filepath, IDLE_STUB):
                return -1
            archived_count += 1
            continue

        if status not in {'done', 'cancelled'}:
            continue

        archive_path = archive_dir / filepath.name
        if archive_path.exists():
            archive_path = archive_dir / f'{filepath.stem}_{timestamp}{filepath.suffix}'

        if dry_run:
            print(f"[DRY-RUN] would archive: {filepath}")
            print(f"[DRY-RUN] would move to: {archive_path}")
            continue

        ensure_parent_dir(archive_path)
        filepath.rename(archive_path)
        archived_count += 1

    return archived_count


def slim_reports(dry_run=False):
    """Returns the number of report files archived, or -1 on error."""
    queue_dir = get_queue_dir()
    reports_dir = queue_dir / 'reports'
    archive_dir = queue_dir / 'archive' / 'reports'

    if not reports_dir.exists():
        return 0

    active_cmd_ids = get_active_cmd_ids()
    timestamp = get_timestamp()
    archived_count = 0

    for filepath in sorted(reports_dir.glob('*.yaml')):
        if filepath.stem in CANONICAL_REPORTS:
            continue

        data = load_yaml(filepath)
        parent_cmd = data.get('parent_cmd') if isinstance(data, dict) else None
        is_active = parent_cmd in active_cmd_ids
        is_stale = (time.time() - filepath.stat().st_mtime) >= 86400

        if not is_stale:
            continue
        if is_active:
            continue

        archive_path = archive_dir / filepath.name
        if archive_path.exists():
            archive_path = archive_dir / f'{filepath.stem}_{timestamp}{filepath.suffix}'

        if dry_run:
            print(f"[DRY-RUN] would archive: {filepath}")
            print(f"[DRY-RUN] would move to: {archive_path}")
            continue

        ensure_parent_dir(archive_path)
        filepath.rename(archive_path)
        archived_count += 1

    return archived_count


_TIMESTAMP_KEY_RE = re.compile(r'(?:^|_)timestamp$', re.IGNORECASE)


def _top_level_duplicate_keys(node):
    """Top-level mapping keys that appear more than once in a document's
    *raw* composed node -- i.e. before PyYAML's constructor silently keeps
    only the last value and hides the collision. Returns a list of the
    duplicated key names (empty if the document isn't a top-level mapping
    or has no duplicates)."""
    if not isinstance(node, yaml.MappingNode):
        return []
    keys = [k.value for k, _ in node.value if isinstance(k, yaml.ScalarNode)]
    seen = set()
    dupes = []
    for k in keys:
        if k in seen and k not in dupes:
            dupes.append(k)
        seen.add(k)
    return dupes


def _max_nested_timestamp(node):
    """Recursively find the latest parseable ISO-8601 value under any key
    matching /(_|^)timestamp$/ anywhere inside a nested dict/list (not just
    the top level -- real canonical reports nest a `timestamp` field one or
    more levels under a named report key, e.g. `report_854_...: {timestamp:
    ...}`). Returns a naive datetime (tzinfo stripped) or None if no
    parseable timestamp is found anywhere in the document.

    tzinfo is stripped rather than reconciled because this repo writes
    timestamps consistently with a +09:00 (JST) offset; stripping preserves
    relative order without needing to handle mixed offsets, and is only
    used to compare documents against each other, never shown to a human."""
    best = None

    def visit(value):
        nonlocal best
        if isinstance(value, dict):
            for key, val in value.items():
                if isinstance(key, str) and _TIMESTAMP_KEY_RE.search(key) and isinstance(val, str):
                    try:
                        parsed = datetime.fromisoformat(val).replace(tzinfo=None)
                    except ValueError:
                        parsed = None
                    if parsed is not None and (best is None or parsed > best):
                        best = parsed
                visit(val)
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(node)
    return best


def _collect_task_ids(node, out):
    """Recursively collect every value found under a `task_id` key anywhere
    inside a nested dict/list, into the `out` set."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == 'task_id' and isinstance(val, str):
                out.add(val)
            _collect_task_ids(val, out)
    elif isinstance(node, list):
        for item in node:
            _collect_task_ids(item, out)


def _current_task_id_for_agent(agent_id):
    """The task_id queue/tasks/{agent_id}.yaml currently assigns this
    agent, or None if the file is missing/idle/malformed."""
    task_file = get_queue_dir() / 'tasks' / f'{agent_id}.yaml'
    data = load_yaml(task_file)
    task = data.get('task') if isinstance(data, dict) else None
    if isinstance(task, dict):
        task_id = task.get('task_id')
        if isinstance(task_id, str):
            return task_id
    return None


def _select_current_entry(entries, agent_id):
    """Pick which document in a multi-document canonical report is the
    live/current one -- WITHOUT relying on its position in the file
    (家老起票2026-09-25 redo・B1: 実データで「先頭が最新」であることが
    判明し、「末尾が最新」という旧前提が偽であると確認された。位置は
    信頼できる新旧の手がかりではない)。

    Priority (軍師が示唆した方式を軸に据える):
      1) queue/tasks/{agent_id}.yaml の現在のtask_idと一致する、
         ただ1件のドキュメント(存在すれば最有力の裏付け)。
      2) ドキュメント内のどこかに現れるtimestampフィールドの再帰的な
         最大値(存在するドキュメントの中で最大のものが現在値)。
      3) いずれでも一意に決められない場合は判定不能として扱い、
         何も退避しない(安全側に倒す)。

    Returns (current_entry_or_None, archived_entries, warnings).
    archived_entries is only ever entries *provably* older than the
    chosen current entry; anything whose recency can't be determined
    (no timestamp, or tied for newest) is left out of archived_entries so
    it stays in the file untouched rather than risk discarding live data."""
    warnings = []

    if len(entries) == 1:
        return entries[0], [], warnings

    current_task_id = _current_task_id_for_agent(agent_id)
    if current_task_id:
        matches = []
        for e in entries:
            ids = set()
            _collect_task_ids(e['doc'], ids)
            if current_task_id in ids:
                matches.append(e)
        if len(matches) == 1:
            archived = [e for e in entries if e is not matches[0]]
            return matches[0], archived, warnings
        if len(matches) > 1:
            warnings.append(
                f"現在のtask_id({current_task_id})が複数ドキュメントに現れており"
                "一意に判定できないため、このファイルは一切退避しない"
            )
            return None, [], warnings

    timestamped = [(e, _max_nested_timestamp(e['doc'])) for e in entries]
    determinable = [(e, ts) for e, ts in timestamped if ts is not None]
    if not determinable:
        warnings.append(
            "いずれのドキュメントにも比較可能なtimestampが見つからず"
            "新旧を判定できないため、このファイルは一切退避しない"
        )
        return None, [], warnings

    max_ts = max(ts for _, ts in determinable)
    winners = [e for e, ts in determinable if ts == max_ts]
    if len(winners) > 1:
        warnings.append(
            "最大timestampを持つドキュメントが複数あり一意に判定できないため、"
            "このファイルは一切退避しない"
        )
        return None, [], warnings

    current = winners[0]
    archived = [e for e, ts in determinable if ts < max_ts]
    return current, archived, warnings


def slim_canonical_reports(dry_run=False):
    """Bloat countermeasure for canonical per-agent report YAML files
    (ashigaru{1-8}_report.yaml / gunshi_report.yaml), which slim_reports()
    explicitly skips (CANONICAL_REPORTS) because they hold the live
    current-status entry karo/gunshi read directly, not a stale/parent_cmd
    -linked artifact that can simply be moved wholesale.

    家老起票2026-09-25(subtask_karo_20260925_watchdog_fixes_redo1)による
    是正: 旧実装は「多重YAMLドキュメントは常に末尾が最新」という前提で
    `docs[:-1]`を無条件に退避していたが、実データ(ashigaru2_report.yaml)
    でこの前提が偽であると判明した(先頭ドキュメントの方が末尾より新しい
    実例が実在した)。現在値の判定はファイル内の位置に一切依存せず、
    `_select_current_entry()`(queue/tasks/{agent}.yamlとの突合を優先し、
    次いでドキュメント内timestampの再帰比較、いずれでも一意に定まらなければ
    何も退避しない)に委ねる。

    加えて、同一ドキュメント内でトップレベルキーが重複する場合(YAMLの
    safe_loadは黙って後勝ちで前の値を握り潰す)を検知し、該当ドキュメントは
    今回のスイープでは一切触れない(触れれば「握り潰された値」を含む状態を
    そのまま確定させてしまうため)。

    退避後も残る2つ目の独立シグナル(B): 現在ドキュメント内で、書いた本人が
    既に「古い」と自己申告しているtrailerキー(CANONICAL_REPORT_OLD_KEY_
    PREFIXES)。

    Returns the number of archived documents+keys across all canonical
    report files, or -1 on error."""
    queue_dir = get_queue_dir()
    reports_dir = queue_dir / 'reports'
    archive_dir = queue_dir / 'archive' / 'reports'

    if not reports_dir.exists():
        return 0

    file_timestamp = get_timestamp()
    archived_count = 0

    for filepath in sorted(reports_dir.glob('*.yaml')):
        if filepath.stem not in CANONICAL_REPORTS:
            continue

        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                text = f.read()
        except OSError as e:
            print(f"Error reading {filepath}: {e}", file=sys.stderr)
            continue

        # nodes(構造・重複キー検知用)と docs(構築済みの値そのもの)は、
        # 同一テキストに対するYAMLの決定的なドキュメント境界解析なので
        # 必ず1対1で対応する。生テキストを都度スライスして再パースする
        # 手法は、複数行ブロックスカラー等を含む実データで境界がずれ
        # 「mapping values are not allowed here」を誘発したため採らない
        # (実データでの検証で発覚・将軍実測)。
        try:
            nodes = [n for n in yaml.compose_all(text) if n is not None]
            docs = [d for d in yaml.safe_load_all(text) if d is not None]
        except yaml.YAMLError as e:
            print(f"Error parsing {filepath}: {e}", file=sys.stderr)
            continue

        if len(nodes) != len(docs):
            # 理論上は起こり得ない(同一テキストの決定的な境界解析)が、
            # 万一の食い違いを検知したら安全側に倒し一切触れない。
            print(
                f"[WARN] {filepath}: ドキュメント数の解析結果が一致しない"
                f"({len(nodes)} nodes vs {len(docs)} docs)ため、"
                "このファイルは今回のスイープでは一切変更しない",
                file=sys.stderr,
            )
            continue

        entries = []
        blocked = False
        for node, doc in zip(nodes, docs):
            dupes = _top_level_duplicate_keys(node)
            if dupes:
                print(
                    f"[WARN] {filepath}: ドキュメント内でトップレベルキー{dupes}が"
                    "重複している(safe_loadが黙って後勝ちで前の値を握り潰す)ため、"
                    "このファイルは今回のスイープでは一切変更しない",
                    file=sys.stderr,
                )
                blocked = True
                continue
            entries.append({'doc': doc})

        if blocked or not entries:
            continue

        agent_id = filepath.stem[:-len('_report')] if filepath.stem.endswith('_report') else filepath.stem
        current_entry, archived_entries, warnings = _select_current_entry(entries, agent_id)
        for w in warnings:
            print(f"[WARN] {filepath}: {w}", file=sys.stderr)

        if current_entry is None:
            continue

        current_doc = current_entry['doc']
        archived_keys = {}
        if isinstance(current_doc, dict):
            for key in list(current_doc.keys()):
                if isinstance(key, str) and key.startswith(CANONICAL_REPORT_OLD_KEY_PREFIXES):
                    archived_keys[key] = current_doc.pop(key)

        archived_docs = [e['doc'] for e in archived_entries]

        if not archived_docs and not archived_keys:
            continue

        if dry_run:
            print(f"[DRY-RUN] would slim canonical report: {filepath} "
                  f"(archive {len(archived_docs)} old document(s), "
                  f"{len(archived_keys)} old key(s))")
            continue

        original_stat = filepath.stat()

        archive_payload = {}
        if archived_docs:
            archive_payload['archived_documents'] = archived_docs
        if archived_keys:
            archive_payload['archived_keys'] = archived_keys

        archive_path = archive_dir / f'{filepath.stem}_{file_timestamp}.yaml'
        if archive_path.exists():
            # 同一秒内に複数の正典reportを処理する場合の衝突回避
            archive_path = archive_dir / f'{filepath.stem}_{file_timestamp}_{len(archived_docs)}_{len(archived_keys)}.yaml'
        ensure_parent_dir(archive_path)
        if not save_yaml(archive_path, archive_payload):
            return -1

        # current以外にも、判定不能で退避しなかった安全な残存ドキュメントが
        # あり得る(位置に依存しない判定の帰結として、生き残るのは1件とは
        # 限らない)。元の相対順序を保ったまま書き戻す。
        archived_ids = {id(e) for e in archived_entries}
        remaining = [e['doc'] for e in entries if id(e) not in archived_ids]

        if len(remaining) == 1:
            if not save_yaml(filepath, remaining[0]):
                return -1
        else:
            try:
                with open(filepath, 'w', encoding='utf-8') as f:
                    yaml.dump_all(remaining, f, allow_unicode=True, sort_keys=False,
                                  default_flow_style=False)
            except Exception as e:
                print(f"Error writing {filepath}: {e}", file=sys.stderr)
                return -1

        # ★console_stall_watchdog.sh(console_subtask_epoch)等、report
        # ファイルのmtimeを「最終活動時刻」の代理指標として読む消費者がいる。
        # 肥大対策の書き込み自体がmtimeを「今」に進めてしまうと、実際には
        # 古い活動なのに「たった今活動があった」と誤認させかねない。
        # 書き込み後に元のmtimeを復元し、この副作用を消す。
        os.utime(filepath, (original_stat.st_atime, original_stat.st_mtime))

        archived_count += len(archived_docs) + len(archived_keys)

    return archived_count


def slim_inbox(agent_id, dry_run=False):
    """Archive read: true messages from inbox file.
    Returns the number of messages archived, or -1 on error."""
    queue_dir = get_queue_dir()
    archive_dir = queue_dir / 'archive'
    inbox_file = queue_dir / 'inbox' / f'{agent_id}.yaml'

    if not inbox_file.exists():
        # Inbox doesn't exist yet - that's fine
        return 0

    data = load_yaml(inbox_file)
    if not data or 'messages' not in data:
        return 0

    messages = data.get('messages') or []
    if not isinstance(messages, list):
        print("Error: messages is not a list", file=sys.stderr)
        return -1

    # Separate unread and archived messages
    unread = []
    archived = []

    for msg in messages:
        is_read = msg.get('read', False)
        if is_read:
            archived.append(msg)
        else:
            unread.append(msg)

    # If nothing to archive, return success without writing
    if not archived:
        return 0

    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'inbox_{agent_id}_{archive_timestamp}.yaml'

    if dry_run:
        print(f"[DRY-RUN] would archive: {inbox_file}")
        print(f"[DRY-RUN] would move to: {archive_file}")
        return 0

    # Write archived messages to timestamped file
    archive_data = {'messages': archived}
    if not save_yaml(archive_file, archive_data):
        return -1

    # Update main file with unread messages only
    data['messages'] = unread
    if not save_yaml(inbox_file, data):
        print(f"Error: Failed to update {inbox_file}, but archive was created", file=sys.stderr)
        return -1

    print(f"Archived {len(archived)} messages from {agent_id} to {archive_file.name}", file=sys.stderr)
    return len(archived)


def slim_shugun_to_karo(dry_run=False):
    """Archive done/cancelled commands from shogun_to_karo.yaml.
    Returns the number of commands archived, or -1 on error."""
    queue_dir = get_queue_dir()
    archive_dir = queue_dir / 'archive'
    shogun_file = queue_dir / 'shogun_to_karo.yaml'

    if not shogun_file.exists():
        print(f"Warning: {shogun_file} not found", file=sys.stderr)
        return 0

    data = load_yaml(shogun_file)
    # Support both 'commands' and 'queue' keys for backwards compatibility
    key = 'commands' if isinstance(data, dict) and 'commands' in data else 'queue'
    if not data or key not in data:
        return 0

    queue = data.get(key, [])
    if not isinstance(queue, list):
        print("Error: queue is not a list", file=sys.stderr)
        return -1

    # Separate active and archived commands
    active = []
    archived = []
    non_canonical = []

    for cmd in queue:
        status = cmd.get('status', 'unknown')
        if status not in LEDGER_CANONICAL_STATUSES:
            non_canonical.append(f"{cmd.get('id', '<missing-id>')}:{status}")
        if status in LEDGER_TERMINAL_STATUSES:
            archived.append(cmd)
        else:
            active.append(cmd)

    # 見える化のみ(自動で正規化はしない)。instructions/common/task_flow.md
    # は non-canonical な status(superseded/hold/shelved 等)を禁じているが、
    # 実データの正規化は家老の判断事項であり、本スクリプトが黙って書き換える
    # べきではない。
    if non_canonical:
        print(
            "[INVENTORY] non-canonical command status (task_flow.mdの正本外): "
            + ", ".join(non_canonical),
            file=sys.stderr,
        )

    # If nothing to archive, return success without writing
    if not archived:
        return 0

    if dry_run:
        print(f"[DRY-RUN] would archive {len(archived)} commands from shogun_to_karo.yaml",
              file=sys.stderr)
        return 0

    # Write archived commands to timestamped file
    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'shogun_to_karo_{archive_timestamp}.yaml'

    archive_data = {key: archived}
    if not save_yaml(archive_file, archive_data):
        return -1

    # Update main file with active commands only
    data[key] = active
    if not save_yaml(shogun_file, data):
        print(f"Error: Failed to update {shogun_file}, but archive was created", file=sys.stderr)
        return -1

    print(f"Archived {len(archived)} commands to {archive_file.name}", file=sys.stderr)
    return len(archived)


def slim_all_inboxes(dry_run=False):
    """Returns the total number of messages archived across all inboxes, or -1 on error."""
    queue_dir = get_queue_dir()
    inbox_dir = queue_dir / 'inbox'
    if not inbox_dir.exists():
        return 0

    total_archived = 0
    for filepath in sorted(inbox_dir.glob('*.yaml')):
        agent_id = filepath.stem
        if dry_run:
            print(f"[DRY-RUN] processing inbox file: {filepath}")
        archived = slim_inbox(agent_id, dry_run=dry_run)
        if archived < 0:
            return -1
        total_archived += archived
        if dry_run:
            print(f"[DRY-RUN] finished inbox file: {filepath}")

    return total_archived


def migration(dry_run=False):
    queue_dir = get_queue_dir()
    legacy_archive_dir = queue_dir / 'reports' / 'archive'
    if not legacy_archive_dir.exists():
        return True

    target_dir = queue_dir / 'archive' / 'reports'
    candidates = sorted(legacy_archive_dir.glob('*.yaml'))
    if not candidates:
        if not dry_run:
            legacy_archive_dir.rmdir()
        return True

    if dry_run:
        print(f"[DRY-RUN] would migrate: {len(candidates)} files")
        return True

    target_dir.mkdir(parents=True, exist_ok=True)
    for path in candidates:
        dest = target_dir / path.name
        path.rename(dest)

    if not any(legacy_archive_dir.iterdir()):
        legacy_archive_dir.rmdir()

    return True


def parse_arguments():
    args = [arg for arg in sys.argv[1:] if arg != '--dry-run']
    dry_run = '--dry-run' in sys.argv[1:]
    if len(args) < 1:
        print("Usage: slim_yaml.py <agent_id> [--dry-run]", file=sys.stderr)
        sys.exit(1)

    return args[0], dry_run


def main():
    """Main entry point."""
    agent_id, dry_run = parse_arguments()

    # Ensure archive directory exists
    queue_dir = get_queue_dir()
    archive_dir = queue_dir / 'archive'
    archive_dir.mkdir(parents=True, exist_ok=True)

    # Process shogun_to_karo if this is Karo (the weekly full-sweep target of
    # cmd_766 layer2). Only this path emits last-run.json, since it's the one
    # that layer3 (watch the cleaner) needs to know actually ran.
    if agent_id == 'karo':
        ledger_path = queue_dir / 'shogun_to_karo.yaml'
        tasks_dir = queue_dir / 'tasks'
        reports_dir = queue_dir / 'reports'
        inbox_dir = queue_dir / 'inbox'

        before_sizes = {
            'ledger': file_size_bytes(ledger_path),
            'tasks': dir_size_bytes(tasks_dir),
            'reports': dir_size_bytes(reports_dir),
            'inbox': dir_size_bytes(inbox_dir),
        }

        ledger_archived = slim_shugun_to_karo(dry_run)
        if ledger_archived < 0:
            sys.exit(1)
        migration(dry_run)
        tasks_archived = slim_tasks(dry_run)
        if tasks_archived < 0:
            sys.exit(1)
        reports_archived = slim_reports(dry_run)
        if reports_archived < 0:
            sys.exit(1)
        canonical_reports_archived = slim_canonical_reports(dry_run)
        if canonical_reports_archived < 0:
            sys.exit(1)
        reports_archived += canonical_reports_archived
        inbox_archived = slim_all_inboxes(dry_run)
        if inbox_archived < 0:
            sys.exit(1)

        if not dry_run:
            after_sizes = {
                'ledger': file_size_bytes(ledger_path),
                'tasks': dir_size_bytes(tasks_dir),
                'reports': dir_size_bytes(reports_dir),
                'inbox': dir_size_bytes(inbox_dir),
            }
            archived_counts = {
                'ledger': ledger_archived,
                'tasks': tasks_archived,
                'reports': reports_archived,
                'inbox': inbox_archived,
            }
            write_last_run_metrics(before_sizes, after_sizes, archived_counts)
    else:
        # Non-karo invocations only slim the caller's own inbox.
        if slim_inbox(agent_id, dry_run) < 0:
            sys.exit(1)

    sys.exit(0)


if __name__ == '__main__':
    main()
