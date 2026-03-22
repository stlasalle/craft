# Autopilot — Project Orchestration System

This repo contains the autopilot workflow system for orchestrating project work through Claude Code.

## Repo Structure

- `bin/` — Orchestrator and helper scripts (shell)
- `bin/lib/` — Shared shell library functions
- `templates/` — Project template (copied when initializing a new project)
  - `templates/.claude/commands/` — Claude Code skills (slash commands)
  - `templates/docs/` — Documentation templates
  - `templates/queue/` — Queue directory structure
- `projects/` — Active project instances (each is a copy of templates/ + customization)
- `shared/` — Cross-project resources (prompt patterns, lessons learned)

## Key Concepts

- **The project folder is the state machine.** Files on disk represent state. Claude reads state, does work, writes new state. Sam reviews state transitions.
- **Queue-based workflow.** Tasks flow through: `pending/` → `approved/` → `in-progress/` → `done/` → archived by consolidation.
- **Tasks are markdown files with YAML frontmatter.** The frontmatter defines metadata (type, milestone, status, QA requirements). The body defines the work.
- **Skills are Claude Code slash commands** in `.claude/commands/`. They read project state, do work, and write results back.
- **The orchestrator** (`bin/orchestrator.sh`) is a persistent daemon that watches the queue, spins up tmux panes for Claude sessions, and monitors lifecycle.

## Conventions

- Shell scripts use bash, are POSIX-friendly where practical
- All paths in scripts are relative to the project root or use `$PROJECT_DIR`
- Task IDs are sequential within a project: `task-001`, `task-002`, etc.
- Milestone IDs use short prefixes: `m1-`, `m2-`, etc.

## Working on This Repo

When modifying skills (templates/.claude/commands/), think about:
1. What state does this skill read?
2. What state does this skill write?
3. What are the failure modes and how should they surface to Sam?
