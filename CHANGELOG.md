# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- `scripts/watcher_supervisor.sh`: @agent_id ベースの動的ペイン解決に改修 (pane-base-index=1 対応、off-by-one 是正)
- `docs/instructions`: tmux pane ハードコード参照 (`multiagent:0.x`, `shogun:main.0`) を実構成 (`agents.1`–`agents.9`, `shogun:main`) に全箇所更新

### Changed
- `scripts/inbox_watcher.sh`: コメント例を `multiagent:agents.1` に更新
- `lib/agent_status.sh`: コメント例を `multiagent:agents.1` に更新
- `instructions/generated/*`: `build_instructions.sh` で再生成

## [4.6.0] - 2026-04-19

### Added
- `shutsujin_departure.sh`: `--auto-mode-on` flag (maps to `--dangerously-skip-permissions`) and `--permission-mode <mode>` for custom permission flags (Issue #124)
- `lib/cli_adapter.sh`: accept `PERMISSION_FLAG` override from departure script, backward-compatible

### Fixed
- Report flow unified to `Ashigaru → Gunshi → Karo` across all instruction files (`instructions/ashigaru.md`, `karo.md`, `gunshi.md`, `CLAUDE.md`, all generated CLI variants) (Issue #121)

### Changed
- `PERMISSION_FLAG` variable centralizes permission handling in `shutsujin_departure.sh` (10 call sites)
- `tests/unit/test_cli_adapter.bats`: additional coverage for permission flag logic

## [4.5.0] - 2026-04-19

### Added
- `scripts/dashboard-viewer.py`: live Markdown viewer for `dashboard.md` via `dash` command (PR #122)
- `first_setup.sh`: auto-register `dash()` function to `.bashrc` on setup
- GitHub Sponsors section to README and README_ja

### Fixed
- `scripts/inbox_write.sh`: self-send guard — prevent agents from messaging themselves (PR #116)
- README quick start: missing `source ~/.bashrc` and `claude --dangerously-skip-permissions` steps (Issue #120)

### Changed
- `tests/test_inbox_write.bats`: updated for mandatory `type`/`from` arguments

## [4.4.2] - 2026-04-10

### Added
- `first_setup.sh`: auto-install OSS skills to `~/.claude/skills/` on setup (skips existing, idempotent)

## [4.4.1] - 2026-03-28

### Added
- Android: Raw/UI toggle in ratelimit dialog for debugging SSH output
- Android: SSH key file picker in settings (load private key from device storage)
- Android: parse failure fallback — show raw output when no data parsed
- `ratelimit_check.sh`: zoom-capture for Codex /status blocks (fixes narrow pane truncation)

### Fixed
- Android: ratelimit display not working (stderr not captured, missing 2>&1)
- Android: SSH private key loading (read file bytes instead of path reference)
- `ratelimit_check.sh`: extract latest /status block with awk parser to avoid stale data

### Changed
- SshManager: capture stderr + log for diagnostics
- AgentsViewModel: show executed command in SSH error messages

## [4.4.0] - 2026-03-28

### Added
- karo daily log: cmd完了時に `logs/daily/YYYY-MM-DD.md` へサマリーを自動追記する機能を導入 (PR #95)
- `.gitignore`: `.claude/settings.local.json` を除外対象に追加

### Changed
- `instructions/karo.md`: ntfy通知ステップを6→7に移動、daily log appendをステップ6に挿入
- `instructions/roles/karo_role.md`: 同期済み
- 全CLI向け generated instructions を再生成（codex/copilot/kimi-karo.md）

## [4.3.0] - 2026-03-28

### Added
- `shutsujin_departure.sh`: all Claude Code agents now launch with `--effort max` by default (shogun, karo, ashigaru, gunshi)

## [4.2.0] - 2026-03-24

### Added
- `install.bat`: dynamically resolve WSL `$HOME` via `wsl -e bash -c "echo $HOME"` so instructions work on any username/PC
- `shutsujin_departure.sh`: `csst` alias now uses `$HOME/multi-agent-shogun` instead of hardcoded path

### Changed
- `install.bat`: repository reference updated from `feature-shogun` to `multi-agent-shogun`
- `config/settings.yaml`: `skills/logs/images` paths changed to relative `./` paths for portability
- `scripts/backup_daily.sh`: cron example uses `$HOME`-based path
- Regenerated `AGENTS.md` and `copilot-instructions.md` (bloom_routing_rule + Post-Compaction Recovery section)

### Fixed
- `inbox_write.sh`: removed `xxd` dependency (CI compatibility)
- `tests/unit/test_idle_flag.bats`: updated T-008 to match v4.0.1 idle flag design (preserve not delete)
