#!/bin/sh
set -e

# Dotfiles install script for devcontainers.
# Expects chezmoi to be pre-installed via the devcontainer feature.
# The devcontainer clones this repo to ~/dotfiles before running this script.

if ! command -v chezmoi >/dev/null 2>&1; then
	echo "ERROR: chezmoi is not installed. Add the chezmoi feature to your devcontainer."
	exit 1
fi

chezmoi init --apply --source="${HOME}/dotfiles/home"
