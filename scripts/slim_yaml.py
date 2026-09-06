#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For Karo: Archives completed task/report files and finished command queue entries.
- For all agents: Archives read: true messages from inbox files.
"""

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import yaml

CANONICAL_TASKS = {f'ashigaru{i}' for i in range(1, 9)} | {'gunshi'}
CANONICAL_REPORTS = {f'ashigaru{i}_report' for i in range(1, 9)} | {'gunshi_report'}
IDLE_STUB = {'task': {'status': 'idle'}}


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

    for cmd in queue:
        status = cmd.get('status', 'unknown')
        if status in ['done', 'cancelled']:
            archived.append(cmd)
        else:
            active.append(cmd)

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
