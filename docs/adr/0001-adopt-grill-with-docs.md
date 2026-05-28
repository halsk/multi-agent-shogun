# Adopt grill-with-docs for ubiquitous language management

We adopt Matt Pocock's [grill-with-docs](https://github.com/mattpocock/skills) skill to enforce consistent terminology across all agents, cmds, and reports in multi-agent-shogun. Without a shared glossary, terms like "task vs subtask", "inbox vs mailbox", or "persona vs role" drift across sessions, causing agent confusion and incorrect behavior.

---

**Status**: accepted
**Date**: 2026-05-28
**mattpocock/skills commit**: `0288510dd61ff6ef7c2003834082ab8f2387e80e`

---

## Context

The multi-agent-shogun system coordinates up to 5+ agents simultaneously. Each agent session starts fresh (after `/clear` or compaction) and reconstructs context from YAML and CLAUDE.md alone. Ambiguous terminology has caused real incidents:

- Karo mistook herself for Ashigaru2 due to persona drift (2026-02-13)
- "task" was used to mean both the YAML file and the subtask execution unit, leading to duplicate work
- "inbox" vs "mailbox" caused agents to look in the wrong location for messages

A CONTEXT.md with canonical definitions, enforced by the grill-with-docs skill, eliminates these ambiguities at the source.

## Decision

1. Install the three upstream files unmodified in `.claude/skills/grill-with-docs/` (Phase 1, this ADR)
2. Add a 戦国口調 wrapper in `.agents/skills/grill-with-docs/` (Phase 2, separate cmd)
3. Create `CONTEXT.md` at the multi-agent-shogun root (Phase 1, this commit)
4. Create `CONTEXT-MAP.md` to document the multi-context plan (Phase 1, this commit)
5. Create per-repo `CONTEXT.md` files for each downstream project (Phase 4, future cmds)

### Placement decision (Q1 = A3)

Both `.claude/skills/` (Claude Code standard) and `.agents/skills/` (project custom) are used. Phase 1 places the upstream files in `.claude/skills/`. Phase 2 will add the wrapper in `.agents/skills/`.

### Activation scope (Q2 = B4)

The skill is available to Tono (direct), Shogun (pre-grilling new cmds), and Gunshi (integration into strategic reports). Not restricted to a single layer.

### Context structure (Q3 = C3 + C1 + C2)

`CONTEXT-MAP.md` at the root (C3) + `CONTEXT.md` for multi-agent-shogun (C1) + per-repo `CONTEXT.md` planned for each downstream project (C2).

### Upstream purity (Q4 = b)

The three upstream files are byte-for-byte copies of the mattpocock/skills repository at the commit SHA above. A 戦国口調 wrapper will be created separately in Phase 2 without modifying the originals.

### Memory / ADR coexistence (Q5 = a)

`memory/project_*_decisions.md` files continue to serve as ADR drafts (殿確定 Q&A format). `docs/adr/` holds confirmed architectural records in the grill-with-docs format. The two are complementary: memory files capture the deliberation; ADR files capture the outcome.

## Considered Options

a) **Do nothing** — terminology drift continues; agent confusion incidents accumulate. Rejected: the cost is already visible in incident logs.

b) **Build a custom glossary system** — bespoke format, no tooling. Rejected: maintenance burden is high and there is no community momentum behind it.

c) **Adopt Matt Pocock's grill-with-docs** (chosen) — proven skill with CONTEXT.md and ADR-FORMAT.md conventions. Upstream updates are simple file replacements. Low lock-in, high signal/noise.

## Consequences

- All new cmds should reference CONTEXT.md terms. Shogun should "grill" new cmd drafts with the skill before issuing.
- When a term in a cmd conflicts with CONTEXT.md, the cm must be updated — not the glossary.
- As downstream repos gain their own CONTEXT.md files, Karo must ensure the correct context file is referenced in the task YAML.
- Phase 2 wrapper must not modify the upstream files; any 戦国口調 adaptation lives in the wrapper only.

## Phase Reference

| Phase | Scope | cmd |
|-------|-------|-----|
| Phase 1 | 本家 3 ファイル設置 + CONTEXT.md + CONTEXT-MAP.md + ADR-0001 | cmd_487 |
| Phase 2 | 戦国口調 wrapper in .agents/skills/ | future cmd |
| Phase 3 | memory/project_*_decisions.md → ADR 棚卸し | future cmd |
| Phase 4 | 各リポ CONTEXT.md 作成 (geonicdb-docs / yuuhitsu / lawsy 等) | future cmds |
