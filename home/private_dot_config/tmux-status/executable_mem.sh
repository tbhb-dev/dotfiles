#!/usr/bin/env bash
# Prints memory in use as a percentage, for the tmux status line.
if [ "$(uname)" = Darwin ]; then
	# Activity Monitor's Memory Used: app (anonymous less purgeable), wired and compressed memory, out of physical memory.
	total=$(sysctl -n hw.memsize)
	vm_stat | awk -v total="$total" '
		/page size of/ { size = $8 }
		/^Anonymous pages/ { anon = $3 }
		/^Pages purgeable/ { purge = $3 }
		/^Pages wired down/ { wired = $4 }
		/^Pages occupied by compressor/ { comp = $5 }
		END { printf "%.0f%%", (anon - purge + wired + comp) * size / total * 100 }'
else
	awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0) printf "%.0f%%", (t - a) / t * 100 }' /proc/meminfo
fi
