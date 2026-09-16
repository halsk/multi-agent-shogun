#!/usr/bin/env bats
# tests/test_ntfy.bats — cmd_811: scripts/ntfy.sh の送信記録+失敗検知の回帰テスト
#
# 是正前は「送信の記録が残らぬ」「失敗(topic誤り・通信断)を黙って呑む(非0で
# 終わらない)」の二つの欠陥があった(2026-09-13殿ご指摘)。本テストは:
#   (a) 成功時にlogs/へ記録が残り、失敗時は非0で終わりログにも残ることを
#   (b) いずれの記録にもntfy_topicの値そのものが含まれないことを
# 実ntfy.sh(https://ntfy.sh)へは一切到達させず、ローカルmockサーバ
# (python http.server)へNTFY_BASE_URLで差し替えて検証する(外部ネットワーク
# 非依存・決定的。CI環境のPython venvは"Setup Python venv with PyYAML"
# ステップで本テストより前に用意済み)。
#
# NTFY_SETTINGS_FILE/NTFY_LOG_FILE/NTFY_BASE_URLは本cmdで新設した上書き口
# (deadman_switch.shのDEADMAN_*と同じ流儀・未指定時は本番既定値のまま)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export NTFY_SCRIPT="$PROJECT_ROOT/scripts/ntfy.sh"
    export LISTENER_SCRIPT="$PROJECT_ROOT/scripts/ntfy_listener.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    [ -f "$NTFY_SCRIPT" ] || return 1
    [ -x "$VENV_PYTHON" ] || VENV_PYTHON="python3"

    export MOCK_SERVER_SCRIPT="$BATS_FILE_TMPDIR/mock_ntfy_server.py"
    export MOCK_CAPTURE_FILE="$BATS_FILE_TMPDIR/mock_capture.jsonl"
    : > "$MOCK_CAPTURE_FILE"
    cat > "$MOCK_SERVER_SCRIPT" <<PY
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
CAPTURE_FILE = "$MOCK_CAPTURE_FILE"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8', errors='replace')
        topic = self.path.lstrip('/')
        code = 200
        # トピック名が "status<code>" の形なら、そのHTTPステータスで応答する
        # (誤topicがサーバへ到達し拒否される状況の再現に使う)。
        if topic.startswith('status'):
            try:
                code = int(topic[len('status'):])
            except ValueError:
                code = 200
        # http.server(email.parser)はヘッダ値をISO-8859-1でデコードするため、
        # curlが送ったUTF-8の生バイトを取り戻すには一旦latin-1へ再エンコードし
        # てからUTF-8として読み直す(そのままjson.dumpsするとTitleが文字化けする)。
        def fix_header(value):
            return value.encode('latin-1', errors='replace').decode('utf-8', errors='replace')
        record = {
            "topic": topic,
            "title": fix_header(self.headers.get('Title', '')),
            "tags": fix_header(self.headers.get('Tags', '')),
            "body": body,
        }
        with open(CAPTURE_FILE, 'a', encoding='utf-8') as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'{}')

    def log_message(self, fmt, *args):
        pass

if __name__ == '__main__':
    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PY

    export MOCK_PORT=$(( 20000 + ($$ % 20000) ))
    "$VENV_PYTHON" "$MOCK_SERVER_SCRIPT" "$MOCK_PORT" &
    export MOCK_SERVER_PID=$!

    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:$MOCK_PORT/status200" && break
        sleep 0.1
    done
}

teardown_file() {
    if [ -n "${MOCK_SERVER_PID:-}" ]; then
        kill "$MOCK_SERVER_PID" 2>/dev/null || true
        wait "$MOCK_SERVER_PID" 2>/dev/null || true
    fi
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_test.XXXXXX")"
    export TEST_LOG_FILE="$TEST_TMPDIR/ntfy_send.log"

    export TEST_SETTINGS_OK="$TEST_TMPDIR/settings_ok.yaml"
    echo 'ntfy_topic: test-topic-regression-abcdef' > "$TEST_SETTINGS_OK"

    # トピック名自体をmockサーバへのHTTPステータス指示に使う(誤topicがサーバに
    # 届いて拒否される状況の再現。実ntfy.shは任意のtopic文字列を受理して発行
    # してしまうため、真の「誤topic」相当の失敗はサーバ側4xx応答で模する)
    export TEST_SETTINGS_BADTOPIC="$TEST_TMPDIR/settings_badtopic.yaml"
    echo 'ntfy_topic: status404' > "$TEST_SETTINGS_BADTOPIC"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "ntfy.sh: 成功(2xx)時はexit 0・logに status=ok を記録する" {
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "hello world"
    [ "$status" -eq 0 ]
    grep -q 'status=ok' "$TEST_LOG_FILE"
}

@test "ntfy.sh: 誤topic(サーバ到達・HTTP 4xxで拒否)はexit非0・logに失敗を記録する" {
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_BADTOPIC" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "bad topic case"
    [ "$status" -ne 0 ]
    grep -q 'fail_http404' "$TEST_LOG_FILE"
}

@test "ntfy.sh: 到達不能ホストはexit非0・logにcurl失敗を記録する" {
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:1" \
    run bash "$NTFY_SCRIPT" "unreachable host case"
    [ "$status" -ne 0 ]
    grep -q 'fail_curl_rc' "$TEST_LOG_FILE"
}

@test "ntfy.sh: 是正前の挙動確認 — 誤topic(HTTP 4xx)はcurl自身は成功するため何もせねばexit 0になっていたはず" {
    # 是正の眼目そのものの回帰防止: HTTPステータスを見ずcurlの終了コードだけを
    # 見るならこの誤topicケースはexit 0(curlはHTTP応答を正常に受け取っている)
    # になる。新版が意図的にHTTPステータスを検査してexit 1にしていることの対照。
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT"
    HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -d "probe" "$NTFY_BASE_URL/status404")
    CURL_RC=$?
    [ "$CURL_RC" -eq 0 ]
    [ "$HTTP_STATUS" = "404" ]
}

@test "ntfy.sh: 送信のたびにlogsへ記録が残り、いずれの記録にもntfy_topicの値そのものが含まれない" {
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "topic leak check ok case"

    NTFY_SETTINGS_FILE="$TEST_SETTINGS_BADTOPIC" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "topic leak check bad case"

    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:1" \
    run bash "$NTFY_SCRIPT" "topic leak check unreachable case"

    [ -s "$TEST_LOG_FILE" ]
    ! grep -q 'test-topic-regression-abcdef' "$TEST_LOG_FILE"
    ! grep -q 'status404' "$TEST_LOG_FILE"
}

@test "ntfy.sh: topic未設定時はexit非0・log記録あり" {
    export TEST_SETTINGS_EMPTY="$TEST_TMPDIR/settings_empty.yaml"
    echo 'other_key: value' > "$TEST_SETTINGS_EMPTY"
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_EMPTY" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "no topic case"
    [ "$status" -ne 0 ]
    grep -q 'fail_no_topic' "$TEST_LOG_FILE"
}

# --- cmd_832: Title型付け(機体/cmd番号/手番種別/所要)+型検証の回帰テスト ---
# 殿ご指摘(2026-09-16): cmd番号が無い/手番の種類が曖昧/所要が分からない/
# 挨拶や内輪の言葉が字数を食う、の4点を解消するため、Titleをscripts/ntfy.sh
# 側で組み立てる新インターフェース(--cmd/--kind/--eta/--body/--detail)を導入。
# 型を欠いた呼び出し(旧位置引数呼出・不正なkind等)は送信を止めず、
# Titleに⚠️マーカーを付けて「そうと判る」形で飛ぶことを検証する。

last_capture() {
    tail -n 1 "$MOCK_CAPTURE_FILE"
}

@test "ntfy.sh: 型付き呼出はTitleに機体・cmd番号・手番種別・所要が入る" {
    : > "$MOCK_CAPTURE_FILE"
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" --cmd cmd_831 --kind 要承認 --eta "2分" \
        --body "Keychain同期を実行してよいか。承認2回で1日864回のop呼出がほぼゼロに" \
        --detail "→ dashboard「cmd_831」節"
    [ "$status" -eq 0 ]
    title=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['title'])" < "$MOCK_CAPTURE_FILE")
    body=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['body'])" < "$MOCK_CAPTURE_FILE")
    echo "title=[$title] body=[$body]" >&3
    echo "$title" | grep -q 'cmd_831'
    echo "$title" | grep -q '要承認'
    echo "$title" | grep -q '2分'
    # 呼び出し側が文字列を組んでいない(旧HOST_TAGそのままの文言ではない)ことの確認
    ! echo "$title" | grep -q '型未指定'
    # 本文は結論(--body)が先頭、詳細の在処(--detail)が後ろに続く
    [[ "$body" == "Keychain同期を実行してよいか。承認2回で1日864回のop呼出がほぼゼロに"*"cmd_831"* ]]
}

@test "ntfy.sh: --cmdを省略すると「運用」表記になり型欠如扱いにならない" {
    : > "$MOCK_CAPTURE_FILE"
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" --kind 要確認 --eta "数分" --body "運用通知の本文"
    [ "$status" -eq 0 ]
    title=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['title'])" < "$MOCK_CAPTURE_FILE")
    echo "$title" | grep -q '運用'
    ! echo "$title" | grep -q '型未指定'
}

@test "ntfy.sh: kindが4種の外/未指定なら「型を欠いた」とTitleでそうと判り、要確認へ倒し、それでも送信する" {
    : > "$MOCK_CAPTURE_FILE"
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" --cmd cmd_999 --kind "存在しない種別" --eta "5分" --body "型欠如テスト"
    [ "$status" -eq 0 ]
    title=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['title'])" < "$MOCK_CAPTURE_FILE")
    echo "$title" | grep -q '型未指定'
    echo "$title" | grep -q '要確認'
}

@test "ntfy.sh: 旧インターフェース(位置引数1つ)は送信は止まらないがTitleに型未指定マーカーが付く" {
    : > "$MOCK_CAPTURE_FILE"
    NTFY_SETTINGS_FILE="$TEST_SETTINGS_OK" \
    NTFY_LOG_FILE="$TEST_LOG_FILE" \
    NTFY_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
    run bash "$NTFY_SCRIPT" "旧型のメッセージ本文"
    [ "$status" -eq 0 ]
    title=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['title'])" < "$MOCK_CAPTURE_FILE")
    body=$(python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['body'])" < "$MOCK_CAPTURE_FILE")
    echo "$title" | grep -q '型未指定'
    [ "$body" = "旧型のメッセージ本文" ]
    grep -q 'status=ok' "$TEST_LOG_FILE"
}

@test "ntfy_listener.sh: 起動ログ行がntfy_topicの値を出力しない(2026-09-13の平文漏洩の再発防止)" {
    run grep -n 'ntfy listener started' "$LISTENER_SCRIPT"
    [ "$status" -eq 0 ]
    # 「topic:」という単語や $TOPIC 変数展開を起動ログ行に含めていないことを
    # 静的に確認する(実際にtopicを漏らしていた行そのものの回帰防止)。
    echo "$output" | grep -qv 'topic'
    ! echo "$output" | grep -q '\$TOPIC'
}

@test "deadman_switch.sh: set -e を使っていない(ntfy.shの非0終了で見張り自体が死なないことの静的保証)" {
    # cmd_811でntfy.shは失敗時に非0で終わるようになった。deadman_switch.shが
    # 万一 set -e (または -e を含む set -euo 等)を持てば、ntfy送信失敗だけで
    # 見張りプロセス自体が落ちる(本末転倒)。現状は set -uo pipefail のみで
    # -e が無いことを確認し、再発を防ぐ。
    run grep -n '^set ' "$PROJECT_ROOT/scripts/deadman_switch.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -qE 'set -[a-zA-Z]*e'
}
