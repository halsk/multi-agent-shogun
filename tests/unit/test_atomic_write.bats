#!/usr/bin/env bats
#
# 台帳再発防止P4: slim_yaml.py / cr_retrigger.py の書込みが原子的であること。
# 2026-10-13: open(path,'w')後にdumpが失敗し台帳が0バイトになった事故の再発防止。
# RED対照: 是正前の旧関数(下のOLD_SAVE)が同じ失敗で元ファイルを壊すことも試験で示す。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$PYTHON_BIN" ] || PYTHON_BIN="python3"
    TMPD="$(mktemp -d)"
    printf 'important: ledger\nentries: [1, 2, 3]\n' > "$TMPD/ledger.yaml"
}

teardown() { rm -rf "$TMPD"; }


@test "RED対照: 旧save_yaml方式は dump失敗で元ファイルを壊す" {
    run "$PYTHON_BIN" -I - "$TMPD/ledger.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
class Bomb(dict):
    def items(self): raise RuntimeError("boom")
try:
    with open(path, 'w', encoding='utf-8') as f:   # 旧実装そのまま
        yaml.dump({"a": Bomb()}, f)
except Exception:
    pass
import os
print(os.path.getsize(path))
PY
    [ "$status" -eq 0 ]
    # 旧方式では (部分書込み含め) 元の内容が失われる
    run grep -q "important: ledger" "$TMPD/ledger.yaml"
    [ "$status" -ne 0 ]
}

@test "是正後: slim_yaml.save_yaml は dump失敗でも元ファイルが無傷" {
    run "$PYTHON_BIN" -I - "$PROJECT_ROOT/scripts" "$TMPD/ledger.yaml" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import slim_yaml
class Bomb(dict):
    def items(self): raise RuntimeError("boom")
ok = slim_yaml.save_yaml(sys.argv[2], {"a": Bomb()})
print("ok=%s" % ok)
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok=False"* ]]
    grep -q "important: ledger" "$TMPD/ledger.yaml"
    [ "$(ls -A "$TMPD" | grep -c atomic_tmp)" -eq 0 ]
}

@test "atomic_write_text: 例外時は元ファイル無傷・一時ファイル残らず" {
    run "$PYTHON_BIN" -I - "$PROJECT_ROOT/scripts/lib" "$TMPD/ledger.yaml" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from atomic_write import atomic_write_text
def w(f):
    f.write("partial")
    raise RuntimeError("boom")
try:
    atomic_write_text(sys.argv[2], w)
except RuntimeError:
    print("raised")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *raised* ]]
    [ "$(cat "$TMPD/ledger.yaml")" = "$(printf 'important: ledger\nentries: [1, 2, 3]')" ]
    [ "$(ls -A "$TMPD" | grep -c atomic_tmp)" -eq 0 ]
}

@test "atomic_write_text: 正常系は置換され権限を維持" {
    chmod 600 "$TMPD/ledger.yaml"
    "$PYTHON_BIN" -I "$PROJECT_ROOT/scripts/lib/atomic_write.py" "$TMPD/ledger.yaml" <<< "new: content"
    [ "$(cat "$TMPD/ledger.yaml")" = "new: content" ]
    [ "$(stat -f %Lp "$TMPD/ledger.yaml" 2>/dev/null || stat -c %a "$TMPD/ledger.yaml")" = "600" ]
}

@test "slim_yaml.py と cr_retrigger.py に非原子的な open(,'w') が残っていない" {
    run grep -nE "open\([^)]*['\"]w['\"]" "$PROJECT_ROOT/scripts/slim_yaml.py"
    [ "$status" -ne 0 ]
    run grep -nE "open\((path|status_path), *\"w\"" "$PROJECT_ROOT/scripts/cr_retrigger.py"
    [ "$status" -ne 0 ]
}
