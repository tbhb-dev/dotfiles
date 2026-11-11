#!/usr/bin/env bash
# Prints total CPU usage as a percentage, for the tmux status line.
if [ "$(uname)" = Darwin ]; then
	# top's first sample is stale, so take the second, one second later.
	idle=$(top -l 2 -n 0 -s 1 | awk '/CPU usage:/ { v = $7 } END { sub("%", "", v); print v }')
else
	idle=$(top -b -n 1 | awk '/Cpu\(s\)/ { for (i = 1; i < NF; i++) if ($(i + 1) ~ /^id/) v = $i } END { print v }')
fi
[ -n "$idle" ] && awk -v idle="$idle" 'BEGIN { printf "%.0f%%", 100 - idle }'
