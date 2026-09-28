#!/usr/bin/env python3
"""finish_task_validate.py — finish_task.sh の報告検め(cmd_914 T1)。

軍師設計(queue/reports/cmd914_status_update_gap.md §3.1「終える操作」③)の
6段のうち③「報告を検める」を担う。以下の全条件を満たさなければ非0で終わり、
finish_task.sh 側はこれを見てから task YAML への書込に進む
(検証と書込を別プロセス呼出に分けることで、片方の判定漏れだけで書込まれる
隙を作らない)。

条件(いずれか一つでも欠ければ INVALID):
1. 単一文書性 — `---` で区切られた複数文書を拒む
2. 重複キーが無い(同一マッピング内の同名キー)
3. 一番上の段(topmost segment)に task_id・status・その他必須欄がそろう
4. 一番上の段の task_id が期待する task_id と同じ
5. 一番上の段の status が期待する status(--status)と同じ
6. report の mtime が task の mtime より新しい

「一番上の段」の取り方: doc 自身が task_id を持てば doc 全体。持たなければ
doc の最初のキー(YAML の出現順=足軽が新しい節を先頭に足す運用に対応)の値が
マッピングであればそれを土台とし、doc のその他のトップレベルの純粋な値
(例: skill_candidate・files_modified のような、本来は同じ節に属すが
歴史的経緯で兄弟キーとして書かれているもの)で不足分を補う。
"""
import argparse
import os
import sys

import yaml

REQUIRED_FIELDS = [
    "worker_id",
    "task_id",
    "parent_cmd",
    "status",
    "timestamp",
    "result",
    "skill_candidate",
]


class _DuplicateKeyError(Exception):
    pass


class _StrictSafeLoader(yaml.SafeLoader):
    """重複キーを検知する SafeLoader(scripts/hooks/queue_yaml_guard.py と同型)。"""

    def construct_mapping(self, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise _DuplicateKeyError(f"duplicate key: {key!r}")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def _top_segment(doc):
    if not isinstance(doc, dict) or not doc:
        return None
    if "task_id" in doc:
        return dict(doc)
    first_key = next(iter(doc))
    nested = doc[first_key]
    if not isinstance(nested, dict):
        return None
    segment = dict(doc)
    segment.pop(first_key, None)
    segment.update(nested)
    return segment


def validate(report_path, expected_task_id, expected_status, task_mtime):
    """(is_valid: bool, detail: str) を返す。"""
    if not os.path.isfile(report_path):
        return False, f"report file not found: {report_path}"

    with open(report_path, "r", encoding="utf-8") as f:
        text = f.read()

    try:
        docs = [d for d in yaml.load_all(text, Loader=_StrictSafeLoader) if d is not None]
    except _DuplicateKeyError as e:
        return False, f"duplicate key: {e}"
    except yaml.YAMLError as e:
        return False, f"yaml syntax error: {e}"

    if len(docs) != 1:
        return False, f"expected exactly 1 YAML document, got {len(docs)}"

    segment = _top_segment(docs[0])
    if segment is None:
        return False, "cannot locate top segment (no task_id-bearing mapping found)"

    missing = [k for k in REQUIRED_FIELDS if k not in segment]
    if missing:
        return False, f"missing required fields: {', '.join(missing)}"

    if str(segment.get("task_id")) != str(expected_task_id):
        return False, (
            f"task_id mismatch: report={segment.get('task_id')!r} "
            f"task={expected_task_id!r}"
        )

    if str(segment.get("status")) != str(expected_status):
        return False, (
            f"status mismatch: report={segment.get('status')!r} "
            f"expected={expected_status!r}"
        )

    report_mtime = os.stat(report_path).st_mtime
    try:
        task_mtime_f = float(task_mtime)
    except (TypeError, ValueError):
        return False, f"invalid --task-mtime: {task_mtime!r}"

    if report_mtime <= task_mtime_f:
        return False, (
            f"report is not newer than task "
            f"(report_mtime={report_mtime}, task_mtime={task_mtime_f})"
        )

    return True, "OK"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--task-mtime", required=True)
    args = parser.parse_args()

    ok, detail = validate(args.report, args.task_id, args.status, args.task_mtime)
    if ok:
        print("VALID")
        sys.exit(0)
    print(f"INVALID: {detail}")
    sys.exit(1)


if __name__ == "__main__":
    main()
