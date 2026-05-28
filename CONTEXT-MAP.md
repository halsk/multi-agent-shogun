# Context Map

This repository (multi-agent-shogun) is the orchestration hub. Its own ubiquitous language is defined in `CONTEXT.md` at this root. Each downstream project repository will have its own `CONTEXT.md` covering domain terms specific to that project.

## Current Contexts

- [multi-agent-shogun](./CONTEXT.md) — orchestration layer: agents, commands, queues, Iron Laws, personas

## Planned Contexts (Phase 4)

Each will live in the respective project repository once `cmd` is issued:

| Repository | Domain | Status |
|------------|--------|--------|
| geolonia/geonicdb-docs | Technical documentation pipeline, translation workflow, yuuhitsu | planned |
| geolonia/yuuhitsu | AST-based Markdown translation library | planned |
| halsk/lawsy | Legal document search and embedding pipeline | planned |
| codeforjapan/ddcr | Disaster data commons, trend forecasting | planned |
| halsk/civic-intelligence-rag | Civic RAG pipeline | planned |
| halsk/PA-001 | Personal automation, transcript management | planned |

## Existing `context/{project}.md` Files (this repo)

The `context/` directory in this repository contains **implementation reference material** for specific projects — not ubiquitous language definitions. These files exist to give Karo and Ashigaru background context when working on a given project's cmd.

| File | Purpose |
|------|---------|
| `context/{project}.md` | Implementation notes, decisions, environment details for a specific project |

**Important distinction**:

- `context/{project}.md` = "How does this project work? What decisions have been made?" (reference material, consumed during cmd execution)
- `CONTEXT.md` (in any repo) = "What do the words we use actually mean?" (glossary, consumed when writing cmds, subtasks, and reports)

These are complementary. A cmd may reference both: `context/geonicdb-docs.md` for implementation context, and geonicdb-docs' own `CONTEXT.md` for domain language.

## Relationships

- **multi-agent-shogun → all downstream repos**: Shogun issues cmds that result in code changes in downstream repos. Terms defined in multi-agent-shogun's `CONTEXT.md` (殿, cmd, subtask, inbox, etc.) apply globally across all agent communication, regardless of which repo is being modified.
- **downstream repo CONTEXT.md → multi-agent-shogun CONTEXT.md**: Domain terms in a project repo (e.g., "translation pipeline", "chunk", "AST node") are local to that repo. They do not override or conflict with orchestration-layer terms.
