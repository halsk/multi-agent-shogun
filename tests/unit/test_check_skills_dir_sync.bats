#!/usr/bin/env bats
#
# tests/unit/test_check_skills_dir_sync.bats
#
# scripts/check_skills_dir_sync.sh の回帰試験(cmd_934 D1)。
#
# 背景: skillの写しが.claude/skillsと.agents/skillsの二か所に別fileとして
# 存在し、symlinkでないまま食い違う事故が実際に起きた(inbox・writing-task-yaml
# の2件、PR#188軍師QC発見)。本スクリプトはこれをCIで機械的に見張る。
#
# Cases:
#   (a) 両方に在りinner contentが一致(通常file) → PASS
#   (b) 両方に在りinner contentが食い違う → FAIL(是正前のinbox/writing-task-yamlを再現)
#   (c) symlink経由で実体が一致 → PASS(whole-vault-deadlink-scanの形を再現)
#   (d) 片方にしか無いskill → 検査対象外としてPASS

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export FIXTURE_ROOT
  FIXTURE_ROOT="$(mktemp -d "$BATS_TMPDIR/skills_sync_fixture.XXXXXX")"
  mkdir -p "$FIXTURE_ROOT/.claude/skills" "$FIXTURE_ROOT/.agents/skills"
}

teardown() {
  rm -rf "$FIXTURE_ROOT"
}

@test "check_skills_dir_sync: matching regular files in both dirs → PASS" {
  mkdir -p "$FIXTURE_ROOT/.claude/skills/matching-skill" "$FIXTURE_ROOT/.agents/skills/matching-skill"
  echo "same content" > "$FIXTURE_ROOT/.claude/skills/matching-skill/SKILL.md"
  echo "same content" > "$FIXTURE_ROOT/.agents/skills/matching-skill/SKILL.md"

  run bash "$PROJECT_ROOT/scripts/check_skills_dir_sync.sh" "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "check_skills_dir_sync: differing content in both dirs (RED 対照・inbox/writing-task-yaml 再現) → FAIL" {
  mkdir -p "$FIXTURE_ROOT/.claude/skills/diverged-skill" "$FIXTURE_ROOT/.agents/skills/diverged-skill"
  echo "claude version content" > "$FIXTURE_ROOT/.claude/skills/diverged-skill/SKILL.md"
  echo "agents version content" > "$FIXTURE_ROOT/.agents/skills/diverged-skill/SKILL.md"

  run bash "$PROJECT_ROOT/scripts/check_skills_dir_sync.sh" "$FIXTURE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"diverged-skill"* ]]
  [[ "$output" == *"食い違っている"* ]]
}

@test "check_skills_dir_sync: .claude side is a symlink to .agents (whole-vault-deadlink-scan の形) → PASS" {
  mkdir -p "$FIXTURE_ROOT/.agents/skills/symlinked-skill" "$FIXTURE_ROOT/.claude/skills/symlinked-skill"
  echo "canonical content" > "$FIXTURE_ROOT/.agents/skills/symlinked-skill/SKILL.md"
  ln -s "../../../.agents/skills/symlinked-skill/SKILL.md" "$FIXTURE_ROOT/.claude/skills/symlinked-skill/SKILL.md"

  run bash "$PROJECT_ROOT/scripts/check_skills_dir_sync.sh" "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "check_skills_dir_sync: skill present on only one side is not checked → PASS" {
  mkdir -p "$FIXTURE_ROOT/.claude/skills/claude-only-skill"
  echo "only in claude" > "$FIXTURE_ROOT/.claude/skills/claude-only-skill/SKILL.md"
  mkdir -p "$FIXTURE_ROOT/.agents/skills/agents-only-skill"
  echo "only in agents" > "$FIXTURE_ROOT/.agents/skills/agents-only-skill/SKILL.md"

  run bash "$PROJECT_ROOT/scripts/check_skills_dir_sync.sh" "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "check_skills_dir_sync: real repo tree (post-fix) has zero divergence" {
  run bash "$PROJECT_ROOT/scripts/check_skills_dir_sync.sh" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}
