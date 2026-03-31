---
name: systematic-debugging
description: バグ修正・エラー調査時に使用。原因特定→仮説検証→修正の体系的アプローチを強制する
---

# Systematic Debugging

## Iron Law

```
原因を特定せずに修正するな。
「とりあえず直してみる」は修正ではなく賭博。
```

## When to Use

- Bug fix tasks
- CI/CD failures
- Test failures
- "It doesn't work" investigations
- Any error that needs diagnosis

## The Four Phases

### Phase 1: Investigate (原因調査)

**Before touching any code:**

1. **Reproduce**: Can you trigger the error? What are the exact steps?
2. **Read the error**: Full stack trace, log output, error message — read ALL of it
3. **Identify the scope**: Which files, functions, or systems are involved?
4. **Gather context**: Recent changes (`git log`), related issues, configuration state

**Output**: A clear statement of what's broken and where

### Phase 2: Hypothesize (仮説立案)

1. List 2-3 possible root causes, ranked by likelihood
2. For each hypothesis, identify what evidence would confirm or refute it
3. Choose the most likely hypothesis to test first

**Output**: Ranked list of hypotheses with test plans

### Phase 3: Test (仮説検証)

1. Test ONE hypothesis at a time
2. Use the smallest possible change to test
3. Record the result: confirmed or refuted
4. If refuted, move to next hypothesis — do NOT stack changes

**Output**: Confirmed root cause with evidence

### Phase 4: Fix (修正実装)

1. Fix the confirmed root cause (not symptoms)
2. Verify the fix resolves the original error
3. Check for side effects (run full test suite, not just the failing test)
4. If the fix changes behavior, document why

**Output**: Working fix with verification evidence

## Common Anti-Patterns

| Anti-Pattern | Correct Approach |
|---|---|
| Change random things until it works | Phase 1-3 first |
| Fix the symptom (suppress error) | Fix the root cause |
| Stack multiple changes to "be sure" | One change per hypothesis |
| Copy-paste a StackOverflow answer | Understand WHY it works before applying |
| Retry the same failing command | Diagnose why it fails |
| "It works on my machine" | Identify the environmental difference |

## Escalation

If after 3 hypotheses none are confirmed:
- Report findings to karo/gunshi with all evidence gathered
- Do NOT continue guessing — fresh perspective needed

## Integration with Report

```yaml
result:
  summary: "Bug X fixed"
  debugging:
    root_cause: "PODCAST_CALENDAR_ID env var unset"
    hypotheses_tested: 3
    fix_applied: "Added fallback + validation in Calendar API Query node"
    verification: "Manual test + unit test added"
```
