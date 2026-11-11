#!/usr/bin/env bash
# Prints total CPU usage as a percentage, for the Linux tmux status line.
idle=$(top -b -n 1 | grep "Cpu(s)" | grep -o "[0-9]\+\(.[0-9]\+\)\? *id" | awk '{ print $1 }')
[ -n "$idle" ] && printf '%.0f%%' "$(echo "100 - $idle" | bc)"
