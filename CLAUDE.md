# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Chezmoi-managed dotfiles repository targeting macOS (Apple Silicon), Ubuntu, and devcontainers. Chezmoi maps files from this repo to the home directory using its naming conventions (e.g., `dot_zshrc.tmpl` → `~/.zshrc`).

## Chezmoi Commands

```bash
chezmoi apply              # Apply changes to home directory
chezmoi apply --force      # Apply, overwriting external modifications
chezmoi diff               # Preview what would change
chezmoi execute-template < home/file.tmpl  # Test template rendering
chezmoi add ~/.<file>      # Add a dotfile to be managed
```

## Repository Structure

The `.chezmoiroot` file sets `home/` as the source root. All managed dotfiles go under `home/` using Chezmoi naming conventions:

- `dot_` prefix → `.` (dotfile)
- `private_` prefix → `0600` permissions
- `.tmpl` suffix → Go template
- See [Chezmoi reference](https://www.chezmoi.io/reference/source-state-attributes/) for full naming rules

### Managed Files

| Source | Target | Purpose |
|--------|--------|---------|
| `home/dot_zshenv.tmpl` | `~/.zshenv` | Universal env vars (every zsh invocation) |
| `home/dot_zprofile.tmpl` | `~/.zprofile` | Login shell: PATH, env vars, tool environments |
| `home/dot_zshrc.tmpl` | `~/.zshrc` | Interactive shell: completions, plugins, aliases, prompt |
| `home/dot_tmux.conf.tmpl` | `~/.tmux.conf` | tmux: prefix, panes, vi keys, TPM plugins |
| `home/private_dot_config/mise/config.toml` | `~/.config/mise/config.toml` | mise tool versions (starship, kubectl, ruby) |
| `home/private_dot_config/starship.toml` | `~/.config/starship.toml` | Starship prompt configuration |
| `home/private_Library/.../private_Code/User/settings.json` | `~/Library/.../Code/User/settings.json` | VS Code user settings |
| `home/private_Library/.../private_Code/User/keybindings.json` | `~/Library/.../Code/User/keybindings.json` | VS Code keybindings |
| `home/private_Library/.../private_Code/User/snippets/ruby.json` | `~/Library/.../Code/User/snippets/ruby.json` | VS Code Ruby snippets |
| `home/dot_gitignore` | `~/.gitignore` | Global git ignore patterns |
| `home/dot_gitconfig.tmpl` | `~/.gitconfig` | Git configuration (user, aliases, signing) |
| `home/private_dot_ssh/private_config.tmpl` | `~/.ssh/config` | SSH hosts, 1Password agent |
| `home/private_dot_config/nvim/` | `~/.config/nvim/` | Neovim (LazyVim) configuration |
| `home/private_dot_config/private_gh/private_config.yml` | `~/.config/gh/config.yml` | GitHub CLI configuration |
| `home/dot_docker/daemon.json` | `~/.docker/daemon.json` | Docker daemon settings |
| `home/run_onchange_after_install-vscode-extensions.sh.tmpl` | _(run script)_ | Install VS Code extensions |
| `home/run_once_after_cleanup-vscode-profiles.sh.tmpl` | _(run script)_ | One-time profile cleanup |

### Zsh File Semantics

- **`.zshenv`** — Runs for every zsh invocation (including scripts). Must be fast, no side effects. Only truly universal env vars.
- **`.zprofile`** — Login shells only, before `.zshrc`. PATH setup, `brew shellenv`, env var exports.
- **`.zshrc`** — Interactive shells only. Aliases, completions, prompt, plugins, key bindings.

## Template Variables

All `.tmpl` files share a common preamble:

```
{{- $isDarwin := eq .chezmoi.os "darwin" -}}
{{- $isLinux := eq .chezmoi.os "linux" -}}
{{- $isDevcontainer := or (env "REMOTE_CONTAINERS") (env "CODESPACES") -}}
{{- $brewPrefix := "/opt/homebrew" (darwin) | "/home/linuxbrew/.linuxbrew" (linux) -}}
```

## Secrets

`.zprofile` exports `OP_ACCOUNT=my.1password.com` in interactive terminals only, after the `SSH_CONNECTION`, `CLAUDECODE` and `CODEX_HOME` check, so ssh sessions and agents never inherit it. Devcontainers skip it. Nothing is read from a secret store at render time, so `chezmoi apply` and `chezmoi diff` need no seeding and no keyring entry.

## Per-host settings

chezmoi derives file modes from the umask. On a host with `umask 0002`, modes in `chezmoi diff` shift (644 to 664, 755 to 775) even though the source is unchanged. Set `umask = 0o022` at the top level of that host's chezmoi config file. The gh config source is `private_config.yml` so it stays mode 0600 on any umask.

Directories that hold credentials carry the `private_` attribute in the source (`.claude`, `.config`, `.config/gh`, `.local`, `.local/share/gh`), so they are 0700 on every host regardless of umask. Other directories take the umask default, so a `umask 0002` host shows 775 versus 755 in `chezmoi diff` unless its chezmoi config sets `umask = 0o022`.

Mac-only trees (`Library`, `Application Support`, `.config/agent-safehouse`) are listed in `home/.chezmoiignore` and skipped off macOS.

A host where agents commit sets `agentSigningIncludes = true` under `[data]` in its chezmoi config. That adds the `includeIf` blocks that make commits under `~/Code/github.com/tbhb-dev/` and `~/Code/scratch/` use `~/.config/devtools/agent-git-signing.gitconfig`. Leave it unset on a host where tbhb commits by hand, since those commits would sign with the agent key.

A host where bare short host names should resolve sets two keys under `[data]` in its chezmoi config: `sshShortHostPrefix`, a string, and `sshShortHostPatterns`, a list of ssh `Host` patterns. `~/.ssh/config` then gets `Host <patterns>` with `Hostname <prefix>%h`, so `ssh ab01` connects to `<prefix>ab01` without waiting on a failing lookup of the short name. Both keys must be set; with either missing the block is omitted. The names live only in each host's own config, never in this repo.

To make zsh a Linux host's login shell, run `sudo -n chsh -s /usr/bin/zsh <user>`. Plain `chsh` asks for the account password through PAM, which fails on accounts with no usable password.

## Multi-Platform Considerations

This repo targets three environments: macOS (Apple Silicon), Ubuntu, and devcontainers. Use Chezmoi's templating to handle platform differences:

- **OS detection:** `{{ if $isDarwin }}` / `{{ if $isLinux }}`
- **Devcontainer detection:** `{{ if $isDevcontainer }}` (checks `REMOTE_CONTAINERS` / `CODESPACES` env vars)
- **Homebrew paths:** Use `$brewPrefix` variable, not hardcoded paths
- **macOS-only blocks:** 1Password SSH agent, Docker Desktop, Ghostty/Zed tmux sockets, Tailscale alias, GNU coreutils PATH
- **Skipped in devcontainers:** `OP_ACCOUNT`, `SSH_AUTH_SOCK`

## Key Configuration Details

- **Prompt:** Starship, installed via mise (not Homebrew)
- **Editor:** Neovim (`nvim`), set in `.zshenv`
- **SSH:** 1Password agent (`SSH_AUTH_SOCK`)
- **Runtime management:** mise (polyglot version manager)
- **Docker:** Binaries symlinked from Docker.app to `~/.docker/bin`, completions from `~/.docker/completions`
- **Terminal multiplexing:** tmux with per-terminal sockets (Ghostty, Zed, VS Code)
- **PATH:** GNU coreutils/sed/tar/curl prioritized over BSD defaults via Homebrew (macOS only)
