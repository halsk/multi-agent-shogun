#!/usr/bin/env python3
"""deadman_switch.sh 用ヘルパー — REPORTED_NOT_CLOSED 判定 (cmd_914【一】T2)。

軍師設計(queue/reports/cmd914_status_update_gap.md §3.2・§4)の条件1〜6を
検める。task YAML の status が assigned/in_progress のまま idle が閾値を
超えた足軽について、対応する報告(queue/reports/{agent}_report.yaml)が
既に done/blocked/failed を告げているのに status が書き戻されていない
「報告済み・未クローズ」を見分けるためのもの。

呼び方: python3 deadman_reconcile.py <task_yaml> <report_yaml>
標準出力(1行・bash側でreadして拾う):
  "CLOSE <status>"        — 条件1〜6すべて充足。task の status を <status> へ
                             書き戻してよい。
  "STALLED <理由>"        — 条件のいずれかが欠ける。従来どおり stalled として
                             報せ、理由を文言に添える。

★fail-safe: 想定外の形・例外は必ず STALLED 側に倒す(閉じる側の誤りは
放置の見逃しに直結するため、疑わしきは stalled として報せる)。
"""
import datetime
import os
import sys

try:
    import yaml
except ImportError:
    print("STALLED PyYAML未導入")
    sys.exit(0)

# ★report: マッピングの直下にある欄(実物のqueue/reports/*.yamlで実証済み)。
# skill_candidate・files_modifiedはreport:と同じ階層(文書のトップレベル)に
# 並ぶ兄弟キーであり、report:マッピングの中には無い(実物で確認済み・
# queue/reports/ashigaru1_report.yaml参照)。
REQUIRED_REPORT_FIELDS = [
    "worker_id", "task_id", "parent_cmd", "status", "timestamp", "result",
]
# ★文書のトップレベルに存在すべき欄(report:と兄弟)。
REQUIRED_TOP_LEVEL_FIELDS = ["skill_candidate"]
VALID_STATUSES = {"done", "blocked", "failed"}


def fail(reason: str) -> None:
    print(f"STALLED {reason}")
    sys.exit(0)


class _DupKeyLoader(yaml.SafeLoader):
    """重複キーがあれば例外を投げる SafeLoader(既定のPyYAMLは後勝ちで黙殺する)。"""


def _no_dup_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"重複キー:{key}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_DupKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup_mapping)


def parse_ts(raw):
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def main() -> None:
    if len(sys.argv) != 3:
        fail("引数不足")
    task_path, report_path = sys.argv[1], sys.argv[2]

    if not os.path.isfile(report_path):
        fail("報告ファイルなし")

    # ── task YAML ──
    try:
        with open(task_path, encoding="utf-8") as f:
            task_raw = f.read()
        task_docs = [d for d in yaml.safe_load_all(task_raw) if d is not None]
    except Exception as e:  # noqa: BLE001 — fail-safe: 何であれSTALLEDへ倒す
        fail(f"task読込失敗:{e}")
    if len(task_docs) != 1 or not isinstance(task_docs[0], dict):
        fail("taskが単一文書でない")
    task = task_docs[0].get("task")
    if not isinstance(task, dict):
        fail("task欄なし")
    task_id = task.get("task_id")
    task_ts = parse_ts(task.get("timestamp"))
    if not task_id or task_ts is None:
        fail("taskにtask_id/timestamp欠落")

    # ── report YAML: 複数文書チェック(条件4の一部) ──
    try:
        with open(report_path, encoding="utf-8") as f:
            report_raw = f.read()
        report_docs = [d for d in yaml.safe_load_all(report_raw) if d is not None]
    except Exception as e:  # noqa: BLE001
        fail(f"report読込失敗:{e}")
    if len(report_docs) != 1:
        fail("reportが単一文書でない(複数文書)")

    # ── 重複キーチェック(条件4の一部) ──
    try:
        list(yaml.load_all(report_raw, Loader=_DupKeyLoader))
    except Exception as e:  # noqa: BLE001
        fail(f"report重複キー:{e}")

    top_doc = report_docs[0]
    report = top_doc.get("report")
    if not isinstance(report, dict):
        fail("report欄なし")

    # ── 必須欄(条件4の一部): report:直下 + 文書トップレベル(skill_candidate) ──
    missing = [k for k in REQUIRED_REPORT_FIELDS if k not in report]
    missing += [k for k in REQUIRED_TOP_LEVEL_FIELDS if k not in top_doc]
    if missing:
        fail(f"report必須欄欠落:{','.join(missing)}")

    # ── 条件1: task_id一致 ──
    if report.get("task_id") != task_id:
        fail("task_idが違う")

    # ── 条件2: status が done/blocked/failed のいずれか ──
    r_status = report.get("status")
    if r_status not in VALID_STATUSES:
        fail(f"reportのstatusが不正:{r_status}")

    # ── 条件3: mtime(report > task) ──
    try:
        task_mtime = os.path.getmtime(task_path)
        report_mtime = os.path.getmtime(report_path)
    except OSError as e:
        fail(f"mtime取得失敗:{e}")
    if report_mtime <= task_mtime:
        fail("報告がtaskより古い(mtime)")

    # ── 条件5: timestamp(report > task) ──
    report_ts = parse_ts(report.get("timestamp"))
    if report_ts is None:
        fail("reportのtimestamp形式が不正")
    if report_ts <= task_ts:
        fail("報告のtimestampがtaskより後でない")

    # 条件1〜5すべて充足。条件6(blockedの文言分岐)はbash側で処理する。
    print(f"CLOSE {r_status}")


if __name__ == "__main__":
    main()
