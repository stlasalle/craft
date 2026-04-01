#!/usr/bin/env bash
# providers.sh — Agent provider abstraction for model-agnostic task execution
#
# Each provider maps to a CLI tool that can accept a prompt and run interactively.
# Add new providers by extending the case statements below.

# Build the tmux command to launch an agent for a task
# Usage: provider_task_cmd <provider> <prompt_file> <work_dir>
provider_task_cmd() {
    local provider="$1" prompt_file="$2" work_dir="$3"

    case "$provider" in
        claude)
            echo "cd '${work_dir}' && claude \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'; exec \$SHELL"
            ;;
        codex)
            echo "cd '${work_dir}' && codex \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'; exec \$SHELL"
            ;;
        *)
            # Generic fallback: assume CLI takes prompt as first positional arg
            echo "cd '${work_dir}' && ${provider} \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'; exec \$SHELL"
            ;;
    esac
}

# Build the tmux command to launch an architect session
# Usage: provider_architect_cmd <provider> <skill_file> <work_dir>
provider_architect_cmd() {
    local provider="$1" skill_file="$2" work_dir="$3"

    case "$provider" in
        claude)
            echo "cd '${work_dir}' && claude \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
        codex)
            echo "cd '${work_dir}' && codex \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
        *)
            echo "cd '${work_dir}' && ${provider} \"\$(cat '${skill_file}')\" ; exec \$SHELL"
            ;;
    esac
}

# Load project-level provider config
# Usage: load_provider_config <project_dir>
# Sets: DEFAULT_AGENT, ARCHITECT_AGENT
load_provider_config() {
    local project_dir="$1"
    local config_file="$project_dir/autopilot.conf"

    # Defaults
    DEFAULT_AGENT="${DEFAULT_AGENT:-claude}"
    ARCHITECT_AGENT="${ARCHITECT_AGENT:-claude}"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    fi
}

# Get the agent provider for a specific task (task-level override or project default)
# Usage: task_agent <task_file>
task_agent() {
    local file="$1"
    local agent
    agent=$(task_field "$file" "agent")
    echo "${agent:-$DEFAULT_AGENT}"
}
