#!/usr/bin/env bash
# .claude/skills/<name>/SKILL.md と .agents/skills/<name>/SKILL.md が
# 両方に存在する場合、内容が一致することを検知する(cmd_934 D1)。
#
# 沿革: skillの写しが.claude/skillsと.agents/skillsの二か所に別fileとして
# 存在し、symlinkでないまま食い違う事故が実際に起きた(PR#188軍師QC・
# inbox/writing-task-yamlの2件)。本スクリプトはCIでこれを機械的に見張る。
# symlinkならdiffは常に一致(同一実体を指すため)、実体が2つのままの場合は
# diffで内容一致を確認する——どちらの形でも同じ基準で検知する。
set -euo pipefail

ROOT_DIR="${1:-.}"
fail=0

for claude_skill_md in "$ROOT_DIR"/.claude/skills/*/SKILL.md; do
  [ -f "$claude_skill_md" ] || continue
  name=$(basename "$(dirname "$claude_skill_md")")
  agents_skill_md="$ROOT_DIR/.agents/skills/$name/SKILL.md"

  if [ ! -f "$agents_skill_md" ]; then
    continue
  fi

  if ! diff -q "$claude_skill_md" "$agents_skill_md" >/dev/null 2>&1; then
    echo "::error::skill '$name' の SKILL.md が .claude/skills と .agents/skills で食い違っている"
    diff "$claude_skill_md" "$agents_skill_md" || true
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "::error::.claude/skills と .agents/skills の二重管理で食い違いを検知した(cmd_934 D1)"
  exit 1
fi

echo "OK: .claude/skills と .agents/skills の両方に在る SKILL.md は全て一致している"
