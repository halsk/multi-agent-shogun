#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="$3"
FROM="$4"

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Initialize inbox if not exists
if [ ! -f "$INBOX" ]; then
    mkdir -p "$(dirname "$INBOX")"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-platform lock: flock (Linux) or mkdir (macOS fallback)
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || return 1
    else
        local i=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
            [ $i -ge 50 ] && return 1  # 5s timeout
        done
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    else
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        # ★root cause fix(cmd_778調査中に発見): このpython呼出をif条件に
        # 包まぬまま素の文として置くと、冒頭の`set -e`により非0終了時に
        # スクリプト全体が直ちに終了し、直後の`STATUS=$?`以降(リトライ
        # ロジック・dedupのexit 3判定)が一切実行されない実バグがあった。
        # if の条件式にすることで`set -e`の対象から除外し、STATUSを
        # 確実に捕捉する。
        if "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, sys

try:
    # Load existing inbox
    with open('$INBOX') as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # cmd_778①redo: report_received の二重通知防止。auto-notify hook
    # (scripts/hooks/report_auto_notify.py)と手動のreport_commandが
    # 同一報告に対し重複発火するケースを吸収する。type=='report_received'
    # に限定することで、他のtype(task_assigned等)の正当な短時間連続
    # 送信を妨げない。
    # ★窓は600秒(10分)→30秒へ短縮(軍師QC指摘・cmd_778①redo)。
    # hookと手動report_commandが同一事象に対し発火する間隔は数秒〜
    # 長くともhookのタイムアウト(20秒)+リトライ分程度に収まる一方、
    # 同一agentが★別の★タスクを完了して正当なreport_receivedを送る
    # 間隔・redoで再度doneにする間隔は、実作業を挟む以上どちらも
    # 数十秒以上かかるのが通常。600秒という長すぎる窓が、後者2つの
    # 正当な報告まで握りつぶしていたのが穴だった。
    if '$TYPE' == 'report_received':
        from datetime import datetime
        DEDUP_WINDOW_SECONDS = 30
        try:
            now_dt = datetime.strptime('$TIMESTAMP', '%Y-%m-%dT%H:%M:%S')
        except ValueError:
            now_dt = None
        if now_dt is not None:
            for m in data['messages']:
                if m.get('from') != '$FROM' or m.get('type') != 'report_received':
                    continue
                try:
                    mt = datetime.strptime(m.get('timestamp', ''), '%Y-%m-%dT%H:%M:%S')
                except (ValueError, TypeError):
                    continue
                if abs((now_dt - mt).total_seconds()) <= DEDUP_WINDOW_SECONDS:
                    print('DEDUP_SKIP: duplicate report_received within window', file=sys.stderr)
                    sys.exit(3)

    # Add new message
    new_msg = {
        'id': '$MSG_ID',
        'from': '$FROM',
        'timestamp': '$TIMESTAMP',
        'type': '$TYPE',
        'content': '''$CONTENT''',
        'read': False
    }
    data['messages'].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages
        data['messages'] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile, os
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname('$INBOX'), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, '$INBOX')
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"; then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        [ $STATUS -eq 0 ] && exit 0
        if [ $STATUS -eq 3 ]; then
            echo "[inbox_write] Skipped: duplicate report_received within dedup window (target=$TARGET, from=$FROM)" >&2
            exit 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
