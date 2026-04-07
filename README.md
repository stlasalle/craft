# Craft

A project orchestration system that runs Claude Code agents autonomously against a queue of tasks, manages their lifecycle, and surfaces work for human review at the right moments.

## Quick Start

### 1. Set up the `craft` CLI

Create a wrapper script and put it on your PATH:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/craft << 'EOF'
#!/usr/bin/env bash
# craft — project orchestrator CLI

CRAFT_ROOT="$HOME/craft"

usage() {
    cat << 'USAGE'
craft — project orchestrator CLI

Usage:
  craft init <project-name>                     Scaffold a new project
  craft <project-name> [options]                Start the orchestrator for a project
  craft config <project-name> [k] [v]           Read or set project config
  craft plugin list                             Show available plugins
  craft plugin add <project> <plugin>           Install a plugin into a project
  craft plugin set <project> <plugin> <k> <v>  Set a plugin config value
  craft plugin show <project> <plugin>          Show a plugin's current config
  craft --help                                  Show this help

Orchestrator options:
  --max-parallel N       Max parallel agents (default: 10)
  --poll-interval SECS   Queue poll interval (default: 15)

Config keys (stored in projects/<name>/craft.conf):
  DEFAULT_AGENT          Agent CLI for task execution  (default: claude)
  ARCHITECT_AGENT        Agent CLI for architect pane  (default: claude)
  OPERATOR_NAME          Your name, used in prompts
  GITHUB_REVIEWER        GitHub username for PR review
  BRANCH_PREFIX          Branch prefix e.g. "sls/"
  PLUGINS                Comma-separated list of enabled plugins

Examples:
  craft init my-project
  craft my-project
  craft config my-project DEFAULT_AGENT codex
  craft plugin list
  craft plugin add my-project slack-dm-notify
  craft plugin set my-project slack-dm-notify SLACK_BOT_TOKEN xoxb-...
  craft plugin set my-project slack-dm-notify SLACK_USER_ID U01ABC123
  craft plugin show my-project slack-dm-notify

Projects are stored in ~/craft/projects/.
USAGE
}

cmd_config() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        echo "Usage: craft config <project-name> [key] [value]"
        exit 1
    fi

    local conf="$CRAFT_ROOT/projects/$project_name/craft.conf"
    if [[ ! -f "$conf" ]]; then
        echo "Project not found: $CRAFT_ROOT/projects/$project_name"
        exit 1
    fi

    local key="${2:-}"
    local value="${3:-}"

    if [[ -z "$key" ]]; then
        echo "Config for $project_name ($conf):"
        grep -v '^#' "$conf" | grep -v '^[[:space:]]*$'
        return
    fi

    if [[ -z "$value" ]]; then
        grep "^${key}=" "$conf" | sed "s/^${key}=//"
        return
    fi

    if grep -q "^${key}=" "$conf" || grep -q "^# ${key}=" "$conf"; then
        sed -i "s|^#\? *${key}=.*|${key}=${value}|" "$conf"
    else
        echo "${key}=${value}" >> "$conf"
    fi
    echo "Set ${key}=${value} in $project_name"
}

_plugins_enable() {
    local conf="$1" plugin="$2"
    local current
    current=$(grep "^PLUGINS=" "$conf" | sed 's/^PLUGINS=//' | tr -d '"' || echo "")
    if [[ -z "$current" ]]; then
        if grep -q "^# PLUGINS=" "$conf"; then
            sed -i "s|^# PLUGINS=.*|PLUGINS=$plugin|" "$conf"
        else
            echo "PLUGINS=$plugin" >> "$conf"
        fi
    else
        if echo "$current" | tr ',' '\n' | grep -qx "$plugin"; then
            return 0
        fi
        sed -i "s|^PLUGINS=.*|PLUGINS=${current},$plugin|" "$conf"
    fi
}

cmd_plugin() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        list)
            echo "Available plugins (in ~/craft/templates/plugins/):"
            for d in "$CRAFT_ROOT/templates/plugins"/*/; do
                local name
                name=$(basename "$d")
                [[ "$name" == "README.md" ]] && continue
                local desc=""
                if [[ -f "$d/hooks.sh" ]]; then
                    desc=$(grep '^#' "$d/hooks.sh" | grep -v '^#!/' | head -1 | sed 's/^# *//')
                fi
                printf "  %-24s %s\n" "$name" "$desc"
            done
            ;;

        add)
            local project_name="${1:-}" plugin_name="${2:-}"
            if [[ -z "$project_name" || -z "$plugin_name" ]]; then
                echo "Usage: craft plugin add <project-name> <plugin-name>"
                exit 1
            fi
            local project_dir="$CRAFT_ROOT/projects/$project_name"
            if [[ ! -d "$project_dir" ]]; then
                echo "Project not found: $project_dir"
                exit 1
            fi
            local template_dir="$CRAFT_ROOT/templates/plugins/$plugin_name"
            if [[ ! -d "$template_dir" ]]; then
                echo "Plugin not found: $template_dir"
                echo "Run 'craft plugin list' to see available plugins."
                exit 1
            fi
            local dest_dir="$project_dir/plugins/$plugin_name"
            if [[ -d "$dest_dir" ]]; then
                echo "Plugin '$plugin_name' is already installed in $project_name."
            else
                cp -R "$template_dir" "$dest_dir"
                echo "Installed $plugin_name into $project_name/plugins/."
            fi
            _plugins_enable "$project_dir/craft.conf" "$plugin_name"
            echo "Enabled $plugin_name in $project_name/craft.conf."
            local conf_keys
            conf_keys=$(grep '^[A-Z_]*=""' "$dest_dir/plugin.conf" 2>/dev/null | sed 's/=.*//')
            if [[ -n "$conf_keys" ]]; then
                echo ""
                echo "Configure it with:"
                while IFS= read -r key; do
                    echo "  craft plugin set $project_name $plugin_name $key <value>"
                done <<< "$conf_keys"
            fi
            ;;

        set)
            local project_name="${1:-}" plugin_name="${2:-}" key="${3:-}" value="${4:-}"
            if [[ -z "$project_name" || -z "$plugin_name" || -z "$key" || -z "$value" ]]; then
                echo "Usage: craft plugin set <project-name> <plugin-name> <key> <value>"
                exit 1
            fi
            local conf="$CRAFT_ROOT/projects/$project_name/plugins/$plugin_name/plugin.conf"
            if [[ ! -f "$conf" ]]; then
                echo "Plugin config not found: $conf"
                echo "Run 'craft plugin add $project_name $plugin_name' first."
                exit 1
            fi
            if grep -q "^${key}=" "$conf" || grep -q "^# ${key}=" "$conf"; then
                sed -i "s|^#\? *${key}=.*|${key}=\"${value}\"|" "$conf"
            else
                echo "${key}=\"${value}\"" >> "$conf"
            fi
            echo "Set ${key} in $project_name/$plugin_name."
            ;;

        show)
            local project_name="${1:-}" plugin_name="${2:-}"
            if [[ -z "$project_name" || -z "$plugin_name" ]]; then
                echo "Usage: craft plugin show <project-name> <plugin-name>"
                exit 1
            fi
            local conf="$CRAFT_ROOT/projects/$project_name/plugins/$plugin_name/plugin.conf"
            if [[ ! -f "$conf" ]]; then
                echo "Plugin not installed. Run: craft plugin add $project_name $plugin_name"
                exit 1
            fi
            echo "Config for $project_name/$plugin_name ($conf):"
            grep -v '^#' "$conf" | grep -v '^[[:space:]]*$'
            ;;

        *)
            echo "Usage: craft plugin <list|add|set|show>"
            exit 1
            ;;
    esac
}

if [[ $# -eq 0 ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
    init)
        exec "$CRAFT_ROOT/bin/init-project.sh" "$@"
        ;;
    config)
        cmd_config "$@"
        ;;
    plugin)
        cmd_plugin "$@"
        ;;
    *)
        PROJECT_NAME="$SUBCOMMAND"
        PROJECT_DIR="$CRAFT_ROOT/projects/$PROJECT_NAME"

        if [[ ! -d "$PROJECT_DIR" ]]; then
            echo "Project not found: $PROJECT_DIR"
            echo ""
            echo "Available projects:"
            ls "$CRAFT_ROOT/projects/" 2>/dev/null || echo "  (none)"
            echo ""
            echo "Create one with: craft init $PROJECT_NAME"
            exit 1
        fi

        exec "$CRAFT_ROOT/bin/orchestrator.sh" "$PROJECT_DIR" "$@"
        ;;
esac
EOF
chmod +x ~/.local/bin/craft
```

Make sure `~/.local/bin` is in your `PATH` (add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile if needed).

### 2. Create a new project

```bash
craft init my-project
```

This scaffolds `projects/my-project/` from the templates, with a project plan, queue directories, and Claude skills pre-installed. Then:

1. Edit `projects/my-project/docs/plan.md` with your project goals and milestones
2. Run the `/generate-milestone` skill in Claude Code to create your first batch of tasks

### 3. Start the orchestrator

```bash
craft my-project
```

This opens a tmux session with the orchestrator dashboard. Approve tasks by moving them from `queue/pending/` to `queue/approved/` — the orchestrator picks them up and starts agents automatically.

---

## What It Does

Craft lets you define a software project as a set of structured tasks, then runs them in parallel using Claude Code — each agent working in its own isolated git worktree, creating a draft PR, running QA, self-reviewing, and monitoring CI and review feedback until the PR merges.

You approve tasks before they run. You review PRs before they merge. Everything in between is automated.

### Task Lifecycle

```
pending/ → approved/ → in-progress/ → waiting/ → done/
                                    ↘ blocked/
```

- **pending** — defined but not yet approved to run
- **approved** — operator has approved; orchestrator will pick these up
- **in-progress** — an agent is actively working
- **waiting** — agent has created a PR and is polling for review/CI feedback
- **done** — PR merged
- **blocked** — agent hit an unrecoverable error; needs human attention

Agents in the `waiting` state stay alive. If the operator pushes review comments, fixes a CI failure, or marks the PR ready — the agent picks it up and responds.

### What an Agent Does (per task)

1. Reads task context — the task file, project plan, milestone doc, relevant ADRs
2. Creates a git worktree for isolated work
3. Implements the changes described in the task
4. Runs QA per the task's `qa:` spec (unit tests, integration tests, local validation)
5. Creates a **draft** PR with conventional commit messages
6. Self-reviews the diff before surfacing it
7. Moves the task to `waiting/` and notifies the operator (via plugins, if configured)
8. Polls the PR — responds to review comments, fixes CI failures, and reacts when the operator marks it ready
9. Moves the task to `done/` when the PR merges

## Repo Structure

```
bin/
  orchestrator.sh          # Persistent daemon — watches queue, spawns agents
  lib/
    queue.sh               # Queue read/write helpers
    tmux.sh                # tmux session/window management
    notify.sh              # Lifecycle notifications (dispatches to plugins)
templates/                 # Blueprint copied when initializing a new project
  .claude/commands/        # Skills (Claude Code slash commands)
    work-task.md           # Main agent skill — executes a task end-to-end
    generate-milestone.md  # Plans and breaks down a milestone into tasks
    split-milestone.md     # Splits a milestone into smaller pieces
    consolidate.md         # Archives a completed milestone
    qa-task.md             # Standalone QA review skill
    audit.md               # Project audit skill
  plugins/                 # Optional integrations (Slack, CI, etc.)
    run-hook.sh            # Hook dispatcher — calls enabled plugins
    slack-daily-thread/    # Example plugin: post PRs to a Slack daily thread
  docs/
    plan.md.template       # Project plan template
    task.md.template       # Task file template
    milestone.md.template  # Milestone doc template
  queue/                   # Queue directory structure (pending, approved, etc.)
  state.md.template        # Project state dashboard template
projects/                  # Active project instances (copies of templates/ + content)
shared/
  prompt-patterns/         # Reusable prompt fragments
  lessons-learned.md       # Cross-project learnings
```

## How to Use

### 1. Initialize a project

Copy `templates/` into `projects/<your-project>/`:

```bash
cp -r templates/ projects/my-project/
```

Fill in `docs/plan.md` with project goals, milestones, and repos.

### 2. Create tasks

Tasks are markdown files with YAML frontmatter. Use `docs/task.md.template` as a starting point, or run the `/generate-milestone` skill to have Claude plan and create tasks from a milestone doc.

Place tasks in `queue/pending/` as `task-001.md`, `task-002.md`, etc.

```yaml
---
id: task-001
type: pr
milestone: m1-foundation
status: pending
depends_on: []
repos: [my-repo]
branch: feat/add-feature
qa:
  unit_tests: true
  integration_tests: false
---

## Summary
Add the thing.

## Acceptance Criteria
1. The thing works.
```

### 3. Approve tasks

Move tasks you're ready to run from `pending/` to `approved/`:

```bash
mv queue/pending/task-001.md queue/approved/
```

### 4. Start the orchestrator

```bash
bin/orchestrator.sh projects/my-project/
```

This opens a tmux session with an orchestrator dashboard window and a planner window. The orchestrator picks up approved tasks, spawns a Claude Code agent per task in its own tmux window, and displays live status.

Options:
- `--max-parallel N` — cap on concurrent agents (default: 10)
- `--poll-interval SECONDS` — how often to check the queue (default: 15)

### 5. Add plugins (optional)

Plugins hook into task lifecycle events. Use the CLI to install and configure them:

```bash
craft plugin list                                            # see what's available
craft plugin add my-project slack-dm-notify                  # install + enable
craft plugin set my-project slack-dm-notify SLACK_BOT_TOKEN xoxb-...
craft plugin set my-project slack-dm-notify SLACK_USER_ID   U01ABC123
```

Available plugins:
- `slack-dm-notify` — DM you when a task has a draft PR or research findings ready
- `slack-daily-thread` — Post PR events to a daily Slack channel thread
- `linear-sync` — Two-way sync with Linear issues

### 6. Review PRs

When an agent finishes a task it moves it to `waiting/` and pings you on Slack with the PR URL. Review the draft PR, mark it ready, and merge when happy. The agent handles CI failures and review comments automatically.

### 7. Blocked tasks

If an agent can't proceed (failed QA it can't fix, unresolvable error), it moves the task to `blocked/` with a detailed work log explaining what happened. The orchestrator surfaces blocked tasks prominently in the dashboard.

## Task Fields Reference

| Field | Description |
|---|---|
| `id` | Sequential task ID, e.g. `task-001` |
| `type` | Always `pr` for now |
| `milestone` | Milestone ID this task belongs to, e.g. `m1-foundation` |
| `status` | Current state: `pending`, `approved`, `in-progress`, `waiting`, `done`, `blocked` |
| `depends_on` | List of task IDs that must be `done` before this task can run |
| `repos` | List of repo names the task will touch |
| `branch` | Git branch name to use for the PR |
| `qa.unit_tests` | Run the repo's unit test suite |
| `qa.integration_tests` | Run integration tests |
| `qa.local_validation` | Shell command to run for validation |
| `qa.qa_env` | Flag for operator: requires QA environment validation |
| `qa.prod_validation` | Flag for operator: requires production validation |
| `pr` | Added by the agent: URL of the created PR |

## Key Principles

- **The project folder is the state machine.** Files on disk represent state. No external database. Everything is readable and editable with a text editor.
- **Agents work in git worktrees.** Each task gets its own worktree under `worktrees/`, so multiple tasks can run in parallel against the same repo without conflicts.
- **You review at two gates: task approval and PR merge.** Everything else is automated.
- **Agents never merge PRs.** They only create draft PRs, self-review, and respond to feedback.
- **Blocked is safe.** If an agent can't proceed it stops and explains clearly rather than guessing or causing damage.
