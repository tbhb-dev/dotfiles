#!/usr/bin/env bash
# Prints memory in use as a percentage, for the Linux tmux status line.
awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0) printf "%.0f%%", (t - a) / t * 100 }' /proc/meminfo
