#!/usr/bin/env bash
set -uo pipefail

# render-watcher-status.sh — One-shot status renderer for a watched PR.
#
# Usage: render-watcher-status.sh <state-file> <json-file>
#
# Reads the watcher's flat-state file (key=value) and the cached
# `gh pr view` JSON. Prints a formatted snapshot to stdout. Caller
# is responsible for clearing the screen / refreshing.

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <state-file> <json-file>" >&2
    exit 1
fi

STATE_FILE="$1"
JSON_FILE="$2"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "render-watcher-status: state file not found: $STATE_FILE" >&2
    exit 1
fi
if [[ ! -f "$JSON_FILE" ]]; then
    echo "render-watcher-status: json file not found: $JSON_FILE" >&2
    exit 1
fi

# ANSI colors
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# Read flat state.
_state_get() {
    local key="$1"
    grep "^${key}=" "$STATE_FILE" | head -1 | sed "s/^${key}=//"
}

state=$(_state_get state)
is_draft=$(_state_get is_draft)
mergeable=$(_state_get mergeable)
checks_conclusion=$(_state_get checks_conclusion)
last_action=$(_state_get last_action)
last_action_at=$(_state_get last_action_at)

# Read JSON.
title=$(jq -r '.title // ""' "$JSON_FILE")
number=$(jq -r '.number // ""' "$JSON_FILE")

# Badge for the PR state.
badge=""
case "$state" in
    OPEN)
        if [[ "$is_draft" == "true" ]]; then
            badge="${YELLOW}DRAFT${NC}"
        else
            badge="${CYAN}READY${NC}"
        fi
        ;;
    MERGED) badge="${GREEN}MERGED${NC}" ;;
    CLOSED) badge="${RED}CLOSED${NC}" ;;
    *)      badge="${DIM}${state}${NC}" ;;
esac

# Header.
printf "%s\n" "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
printf "%s PR #%s — %s   %b\n" "${BOLD}" "$number" "$title" "$badge"
printf "%s mergeable: %s\n" "${DIM}" "$mergeable${NC}"
printf "%s\n" "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# CI Checks
# Display name precedence: context (status checks like Buildkite) →
# workflowName (GitHub Actions) → name (everything else) → "(unnamed)".
# `gh pr view --json statusCheckRollup` populates a different field
# depending on the check provider, so coalesce them.
echo "${BOLD}CI Checks${NC}"
jq -r '
    .statusCheckRollup // []
    | .[]
    | "\(.context // .workflowName // .name // "(unnamed)")\t\(.conclusion // "")\t\(.status // "")"
' "$JSON_FILE" | while IFS=$'\t' read -r name concl status; do
    icon=""
    case "$concl" in
        SUCCESS) icon="${GREEN}✓${NC}" ;;
        FAILURE) icon="${RED}✗${NC}" ;;
        *)
            case "$status" in
                IN_PROGRESS|PENDING|QUEUED) icon="${YELLOW}●${NC}" ;;
                *) icon="${DIM}?${NC}" ;;
            esac
            ;;
    esac
    printf "  %b %s\n" "$icon" "$name"
done
echo ""

# Reviews
echo "${BOLD}Reviews${NC}"
review_lines=$(jq -r '
    .reviews // []
    | map("\(.author.login // "?")\t\(.state // "?")")
    | .[]
' "$JSON_FILE")
if [[ -z "$review_lines" ]]; then
    echo "  ${DIM}(none)${NC}"
else
    echo "$review_lines" | while IFS=$'\t' read -r who st; do
        case "$st" in
            APPROVED)          col="${GREEN}" ;;
            CHANGES_REQUESTED) col="${RED}" ;;
            *)                 col="${DIM}" ;;
        esac
        printf "  %s%-12s%b %s\n" "$col" "$who" "${NC}" "$st"
    done
fi
echo ""

# Last action
echo "${BOLD}Last Action${NC}"
if [[ -n "$last_action" ]]; then
    printf "  %s %s%s%s\n" "$last_action" "${DIM}" "$last_action_at" "${NC}"
else
    echo "  ${DIM}(none yet)${NC}"
fi
echo ""

# Footer
printf "%s%sUpdated: %s%s\n" "${DIM}" "" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${NC}"
