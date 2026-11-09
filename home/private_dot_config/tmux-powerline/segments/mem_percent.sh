#!/usr/bin/env bash
# Prints memory usage as a percentage.

run_segment() {
	read -r mem_used_bytes mem_total_bytes < <(__tp_mem_used_info)

	if [ -n "$mem_used_bytes" ] && [ -n "$mem_total_bytes" ]; then
		printf "%.0f%%" "$(echo "$mem_used_bytes / $mem_total_bytes * 100" | bc -l)"
		return 0
	else
		return 1
	fi
}
