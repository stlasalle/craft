#!/usr/bin/env bash
# slack-daily-thread — Posts PR events to a daily Slack thread
#
# Requires plugin.conf to be configured with SLACK_CHANNEL and SLACK_BOT_PATH.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load plugin config
# shellcheck source=/dev/null
source "$PLUGIN_DIR/plugin.conf"

if [[ -z "$SLACK_CHANNEL" || -z "$SLACK_BOT_PATH" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Called when a PR is marked as ready (draft → ready)
on_ready() {
    local pr_url="" pr_number="" pr_title=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr-url) pr_url="$2"; shift 2 ;;
            --pr-number) pr_number="$2"; shift 2 ;;
            --pr-title) pr_title="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Get today's thread timestamp
    local thread_ts
    thread_ts=$("$SLACK_BOT_PATH/pr-thread-cache.sh" get 2>/dev/null) || return 0

    "$SLACK_BOT_PATH/post.sh" \
        --channel "$SLACK_CHANNEL" \
        --thread "$thread_ts" \
        --text "${pr_title} - <${pr_url}|#${pr_number}>"
}
