---
name: verification-before-completion
description: 完了報告前の検証を強制する。足軽・軍師が「完了」と報告する前に必ず呼び出す
---

# Verification Before Completion

## Iron Law

```
完了と報告するなら、証拠を見せよ。
証拠なき完了報告は虚偽報告と同じ。
```

## When to Use

**Every time** you are about to write a completion report (`status: done`).
No exceptions. Not even for "trivial" tasks.

## The Checklist

Before writing your report YAML with `status: done`, verify ALL applicable items:

### 1. Deliverables Exist

- [ ] All files listed in `files_modified` actually exist (Read or Glob to confirm)
- [ ] File contents match what you intended (Read the file, don't trust memory)
- [ ] No placeholder content left behind (`TODO`, `FIXME`, `TBD`)

### 2. Tests Pass

- [ ] Run tests relevant to your changes
- [ ] **SKIP = FAIL**: Any skipped test means the task is NOT complete
- [ ] If no test suite exists, state that explicitly in your report

### 3. Build Succeeds

- [ ] If the project has a build system, run it (`npm run build`, `pnpm build`, etc.)
- [ ] Build warnings reviewed — no new warnings from your changes

### 4. Purpose Alignment

- [ ] Re-read `parent_cmd` in `queue/shogun_to_karo.yaml`
- [ ] Compare your deliverable against the cmd's `purpose` and `acceptance_criteria`
- [ ] If there's a gap, note it in `purpose_gap:` field — do NOT silently mark done

### 5. Fresh Evidence

- [ ] Evidence must come from THIS verification, not from memory of earlier work
- [ ] If you "already checked earlier" — check again. State can change between edits

## Common Rationalizations (all invalid)

| Rationalization | Why It's Wrong |
|---|---|
| "I just wrote this code, I know it works" | You're testing your memory, not the code |
| "The tests passed earlier" | Earlier ≠ now. You may have changed something since |
| "It's a trivial change, no need to verify" | Trivial changes cause production outages |
| "I'll check after submitting the report" | Report = claim of completion. Verify FIRST |
| "The build takes too long" | Time cost of verification < cost of redo |
| "SKIP tests don't matter, they were already skipped" | SKIP = FAIL. Always. Period. |

## Report Enhancement

When writing your report, include verification evidence:

```yaml
result:
  summary: "..."
  verification:
    tests_run: "pnpm test — 42 passed, 0 failed, 0 skipped"
    build: "pnpm build — success, 0 warnings"
    files_verified: ["src/foo.ts", "src/bar.ts"]
    purpose_check: "acceptance_criteria 1-3 all met"
```

## Integration

This skill supplements (does not replace) the autonomous judgment rules in `instructions/ashigaru.md`.
The key difference: this skill is about **evidence**, not just self-review.
