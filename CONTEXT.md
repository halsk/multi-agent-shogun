# multi-agent-shogun

This context defines the ubiquitous language for the multi-agent-shogun orchestration system — a hierarchical multi-agent framework where human intent flows from Tono through Shogun to Karo, and is executed by Ashigaru under Gunshi's strategic oversight.

## Language

### Principals

**殿 (Tono)**:
The ultimate decision-maker of the project who issues high-level directives to the Shogun. All final approvals and strategic direction originate here.
_Avoid_: Lord (English gloss only), ボス, 主君

**将軍 (Shogun)**:
The top command agent who receives Tono's intent and issues `cmd` directives to Karo for decomposition and execution.
_Avoid_: Manager, boss agent

**家老 (Karo)**:
The task-manager agent who receives `cmd` from Shogun, decomposes them into `subtask` units, and assigns them to Ashigaru and Gunshi.
_Avoid_: Coordinator

**軍師 (Gunshi)**:
The senior strategy and analysis agent (runs on Opus model) responsible for deep research, feasibility reviews, and quality checks before Karo acts.
_Avoid_: Analyst only (Gunshi also conducts quality checks)

**足軽 (Ashigaru)**:
A worker agent that executes implementation subtasks. Multiple Ashigaru run in parallel, each in their own tmux pane.
_Avoid_: Worker, slave

### Work Units

**cmd**:
A directive issued by Shogun to Karo, recorded in `queue/shogun_to_karo.yaml`. A cmd represents one meaningful unit of work with a `north_star` and `acceptance_criteria`.
_Avoid_: ticket, issue (those are GitHub constructs), task (use subtask for execution units)

**subtask**:
The execution unit Karo assigns to an individual Ashigaru. Derived by decomposing a `cmd`. Stored as `queue/tasks/{agent_id}.yaml`.
_Avoid_: job, step

**north_star**:
The one-sentence statement in a cmd that defines its ultimate goal and justification. If a decision conflicts with the north_star, it signals scope drift.
_Avoid_: goal (broader and less constraining)

**acceptance_criteria**:
The concrete, verifiable list of conditions that must all be met before a cmd or subtask can be marked `done`. Failing any one criterion means the task is not complete.
_Avoid_: requirements (those belong to a planning phase, not a completion check)

### System Concepts

**inbox**:
A file-based message queue at `queue/inbox/{agent_id}.yaml` used for all agent-to-agent communication. Messages are written by `inbox_write.sh` and delivered by `inbox_watcher.sh`.
_Avoid_: mailbox (confusing), channel

**dashboard**:
The file `dashboard.md` — a human-readable summary maintained by Karo and Gunshi for Shogun/Tono to read. It is secondary information; YAML files are the authoritative source of truth.
_Avoid_: status report (implies it is primary — it is not)

**Iron Laws**:
The absolute, unconditional rules listed in `CLAUDE.md` that apply to every agent without exception. No task, cmd, or agent (including Shogun) can override them.
_Avoid_: guidelines (Iron Laws cannot be broken)

**Forbidden Actions**:
A per-agent list of prohibited behaviors defined in `instructions/{agent}.md`. Each agent role has a distinct set tailored to its scope and authority level.
_Avoid_: restrictions (implies they can be lifted under negotiation — they cannot)

**persona**:
The combination of role definition, speech style (戦国口調), and behavioral constraints that an agent must maintain throughout a session. Lost on `/clear`; restored by the SessionStart hook.
_Avoid_: role (role describes what you do; persona describes how you behave while doing it)

**戦国口調 (Sengoku-tone)**:
The feudal Japanese speech style (〜でござる、〜つかまつる、〜いたす) applied to agent dialogue and commentary — not to code, YAML values, or commit messages.
_Avoid_: formal Japanese (too vague; Sengoku-tone is a specific historical register)

## Flagged Ambiguities

**task vs subtask**: In daily speech "task" is often used loosely. In this system, `task` refers to the YAML file (`queue/tasks/{agent}.yaml`) that holds the current `subtask`. Always say `subtask` when referring to the execution unit, and `task YAML` when referring to the file.

**context/{project}.md vs CONTEXT.md**: These are distinct artefacts. `context/{project}.md` contains implementation reference material for a specific project, used by Karo and Ashigaru during cmd execution. `CONTEXT.md` (this file) is the ubiquitous language glossary. Neither replaces the other.

## Example Dialogue

> **Tono**: 将軍よ、grill-with-docs を導入いたせ。
>
> **Shogun**: 御意にございます。家老に cmd_487 を発令いたしまする。north_star は「Matt Pocock 本家スキルを設置し、ubiquitous language glossary を整備すること」にございます。
>
> **Karo**: 将軍様、cmd_487 を拝受いたしました。acceptance_criteria を確認し、subtask_487a として足軽1号に割り当てまする。worktree は `/home/hal/workspace/multi-agent-shogun-wt1` に設ける予定にございます。
>
> **Ashigaru1**: 家老殿、inbox に subtask を頂戴いたしました。Iron Laws を遵守しつつ、feature ブランチにて実装を進めまする。完了の暁には karo inbox へ報告つかまつります。
>
> **Karo**: *(dashboard.md を更新し、Tono が読めるよう二次情報として反映する)*
