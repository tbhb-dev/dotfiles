#!/usr/bin/env bash
# Prints total CPU usage as a single percentage.

run_segment() {
	if tp_shell_is_linux; then
		cpu_idle=$(top -b -n 1 | grep "Cpu(s)" | grep -o "[0-9]\+\(.[0-9]\+\)\? *id\(le\)\?" | awk '{ print $1 }')
	elif tp_shell_is_macos; then
		cpu_idle=$(top -e -l 1 | grep "CPU usage:" | awk '{print $7}' | sed 's/%//')
	fi

	if [ -n "$cpu_idle" ]; then
		printf "%.0f%%" "$(echo "100 - $cpu_idle" | bc)"
		return 0
	else
		return 1
	fi
}
