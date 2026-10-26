#!/bin/sh
# Runs a command with its output in LOG, printing a progress line every 30 seconds.
#
#   scripts/run-with-heartbeat.sh LOG COMMAND...
#
# xcodebuild's archive and export say nothing for tens of minutes and their logs run to megabytes, so
# streaming them floods the job log and redirecting them leaves nothing to watch at all. This reports
# how long the command has been running, how far its log has grown and what's left on the disk, and
# exits with the command's own status.
set -eu

LOG="${1:?usage: $0 LOG COMMAND...}"
shift

: > "$LOG"
"$@" >> "$LOG" 2>&1 &
pid=$!

started=$(date +%s)
ticks=0
# Polled often so a quick failure is noticed at once, reported every sixth tick.
while kill -0 "$pid" 2> /dev/null; do
    sleep 5
    ticks=$((ticks + 1))
    if [ "$((ticks % 6))" -eq 0 ]; then
        printf '%5ds  %8s log lines  %6s free\n' \
            "$(($(date +%s) - started))" \
            "$(wc -l < "$LOG" | tr -d ' ')" \
            "$(df -h . | awk 'NR == 2 { print $4 }')"
    fi
done

# The child is still reapable, so this is its exit status and set -e passes it on.
wait "$pid"
