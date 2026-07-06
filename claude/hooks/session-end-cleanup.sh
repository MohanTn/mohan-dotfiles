#!/usr/bin/env bash
# SessionEnd — prune stale state to bound growth of the hook state dir
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks"
find "$state_home" -maxdepth 1 -type d -mtime +7 ! -name claude-hooks ! -name digests ! -name logs -exec rm -rf {} + 2>/dev/null
find "$state_home/logs" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
find "$state_home/digests" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
exit 0
