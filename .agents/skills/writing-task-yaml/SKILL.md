---
name: writing-task-yaml
description: 家老がタスクYAMLを書く時に使用。足軽が迷わない明確なタスク記述を保証する
---

# Writing Task YAML

## Iron Law

```
足軽はタスクYAMLに書かれたことしかやらない。
書かれていないことは実行されない。
```

## When to Use

Karo writes task YAML for ashigaru assignment (Step 5-6 of karo workflow).

## The Bite-Sized Task Rule

Each task MUST be completable in a single session without ambiguity.

### Required Specificity

| Field | Bad | Good |
|---|---|---|
| description | "Fix the tests" | "Fix infra-inspection.spec.ts: replace `testid=tenant-selector` with `testid=service-path-selector` on lines 45, 78, 112" |
| target_path | (omitted) | "/home/hal/workspace/geonicdb-demo-app" |
| files to modify | "Update the components" | "Modify: `src/pages/InfraInspection.tsx`, `src/components/ServicePathSelector.tsx`" |
| acceptance_criteria | "Tests pass" | "pnpm test -- infra-inspection → 0 fail, 0 skip. pnpm build → success" |

### Mandatory Sections in description

1. **What**: Specific deliverable (file paths, function names, exact changes)
2. **Why**: Context from parent cmd (enough for the ashigaru to make judgment calls)
3. **How to verify**: Exact commands to confirm success
4. **Constraints**: Things NOT to do (scope boundaries)

### Standard Inclusions (from Lessons Learned)

Every task YAML MUST include these unless explicitly inapplicable:

```yaml
description: |
  [task description]

  ■ Git ルール
  - main から新しいブランチを切ること (base_branch: main)
  - commit --amend 禁止。修正は新しいコミットとして積むこと
  - main 直接 commit/push 禁止

  ■ 品質チェック
  - push前に /code-review-expert --auto でレビュー実行
  - SKIP = FAIL: テストにSKIPがあれば未完了扱い
  - CHANGELOG.md を更新すること（該当する場合）

  ■ 口調
  - 独り言・報告は戦国武士風（〜でござる、〜つかまつる）
```

### Worktree Tasks (同一リポ複数足軽作業時)

```yaml
description: |
  [task description]

  ■ Worktree 手順
  - git worktree add /home/hal/workspace/{repo}-wt{N} -b {branch} origin/main
  - 作業は worktree 内で行うこと
  - メインリポは触らない
  - 作業完了後: git worktree remove /home/hal/workspace/{repo}-wt{N}
```

## Anti-Patterns

| Pattern | Problem | Fix |
|---|---|---|
| Forwarding shogun's cmd verbatim | Ashigaru gets vague instructions | Decompose into specific subtasks |
| "Do what's needed" | Ashigaru scope-creeps or under-delivers | Explicit scope with boundary |
| Missing acceptance_criteria | No way to verify completion | Add testable conditions |
| No git instructions | Ashigaru commits to wrong branch or amends | Always include git rules |
| Assuming shared context | Ashigaru doesn't have karo's session context | Include ALL needed context in YAML |
