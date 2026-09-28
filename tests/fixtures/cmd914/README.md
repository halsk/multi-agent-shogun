# cmd_914 fixtures — status update gap (finish_task.sh)

出所: 軍師の調査(`queue/reports/cmd914_status_update_gap.md` §2.2)。

`ashigaru1_task_cmd911_e1_e2_vault_write.yaml` / `ashigaru1_report_cmd911_e1_e2_vault_write.yaml` は、
2026-09-28 時点で実際に発生していた食い違いの実物のコピーである
(`queue/tasks/ashigaru1.yaml` と `queue/reports/ashigaru1_report.yaml`、
`task_id: subtask_cmd911_e1_e2_vault_write`)。

- task YAML: `status: assigned`(mtime 16:51:23 時点)
- report YAML: 同じ `task_id`・`status: done`(mtime 16:54:18 時点)

報告は done と書いたが、当時 task YAML の status を done へ戻す手順が
どこにも無かった(足軽の正典 `.claude/skills/inbox/SKILL.md` に status 更新の
段が無かったことが真因)ため、task YAML は assigned のまま取り残されていた。

`tests/unit/test_finish_task.bats` の GREEN 実証テストは、この実物のコピーを
隔離環境へ複製し mtime を調整した上で `finish_task.sh` を実行し、
status が `done` へ書き換わることを示す——本 fixture が表す実際の穴が
`finish_task.sh` によって塞がれることの証拠とする。

★本物の `queue/tasks/ashigaru1.yaml`・`queue/reports/ashigaru1_report.yaml` は
このコピー作成後も一切変更していない(家老が fixture 化確認後に別途整理する)。
