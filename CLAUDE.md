# Repository guide

@AGENTS.md

## Overview

This chezmoi-managed dotfiles repository targets macOS (Apple Silicon), Ubuntu, and devcontainers. chezmoi maps files from this repo to the home directory using its naming conventions: `dot_zshrc.tmpl` → `~/.zshrc`.

## chezmoi commands

```bash
chezmoi apply              # Apply changes to home directory
chezmoi apply --force      # Apply, overwriting external modifications
chezmoi diff               # Preview what would change
chezmoi execute-template < home/file.tmpl  # Test template rendering
chezmoi add ~/.<file>      # Add a dotfile to be managed
```

## Repository structure

The `.chezmoiroot` file sets `home/` as the source root. All managed dotfiles go under `home/` using chezmoi naming conventions:

- `dot_` prefix → `.` (hidden file)
- `private_` prefix → `0600` permissions
- `.tmpl` suffix → Go template
- See [chezmoi reference](https://www.chezmoi.io/reference/source-state-attributes/) for full naming rules

### Managed files

| Source | Target | Purpose |
|--------|--------|---------|
| `home/dot_zshenv.tmpl` | `~/.zshenv` | Universal environment variables (every `zsh` invocation) |
| `home/dot_zprofile.tmpl` | `~/.zprofile` | Login shell: `PATH`, environment variables, tool environments |
| `home/dot_zshrc.tmpl` | `~/.zshrc` | Interactive shell: completions, plugins, aliases, prompt |
| `home/dot_tmux.conf.tmpl` | `~/.tmux.conf` | `tmux`: prefix, panes, vi keys, plugins |
| `home/private_dot_config/mise/config.toml` | `~/.config/mise/config.toml` | mise tool versions (`starship`, kubectl, ruby) |
| `home/private_dot_config/starship.toml` | `~/.config/starship.toml` | `starship` prompt configuration |
| `home/private_Library/.../private_Code/User/settings.json.tmpl` | `~/Library/.../Code/User/settings.json` | VS Code user settings |
| `home/private_Library/.../private_Code/User/keybindings.json` | `~/Library/.../Code/User/keybindings.json` | VS Code keybindings |
| `home/private_Library/.../private_Code/User/snippets/ruby.json` | `~/Library/.../Code/User/snippets/ruby.json` | VS Code Ruby snippets |
| `home/dot_gitignore` | `~/.gitignore` | Global git ignore patterns |
| `home/dot_gitconfig.tmpl` | `~/.gitconfig` | Git configuration (user, aliases, signing) |
| `home/private_dot_ssh/private_config.tmpl` | `~/.ssh/config` | Secure Shell (SSH) hosts, 1Password agent |
| `home/private_dot_config/nvim/` | `~/.config/nvim/` | Neovim (LazyVim) configuration |
| `home/private_dot_config/private_gh/private_config.yml` | `~/.config/gh/config.yml` | GitHub `gh` tool configuration |
| `home/dot_docker/daemon.json` | `~/.docker/daemon.json` | Docker daemon settings |
| `home/run_onchange_after_install-vscode-extensions.sh.tmpl` | _(run script)_ | Install VS Code extensions |
| `home/run_once_after_cleanup-vscode-profiles.sh.tmpl` | _(run script)_ | One-time profile cleanup |

### Zsh file semantics

- **`.zshenv`**: runs for every zsh invocation, including scripts. Side effects and slow commands don't belong here. It contains only truly universal environment variables.
- **`.zprofile`**: runs in login shells only, before `.zshrc`. It holds `PATH` setup, `brew shellenv` and environment variable exports.
- **`.zshrc`**: runs in interactive shells only. It holds aliases, completions, the prompt, plugins, and key bindings.

## Template variables

All `.tmpl` files share a common preamble:

```text
{{- $isDarwin := eq .chezmoi.os "darwin" -}}
{{- $isLinux := eq .chezmoi.os "linux" -}}
{{- $isDevcontainer := or (env "REMOTE_CONTAINERS") (env "CODESPACES") -}}
{{- $brewPrefix := "/opt/homebrew" (darwin) | "/home/linuxbrew/.linuxbrew" (linux) -}}
```

## Secrets

`.zprofile` exports `OP_ACCOUNT=my.1password.com` in interactive terminals only, after the `SSH_CONNECTION`, `CLAUDECODE` and `CODEX_HOME` check, so `ssh` sessions and agents never inherit it. Hosts in devcontainers skip it. The templates read nothing from a secret store at render time, so `chezmoi apply` and `chezmoi diff` don't need seeding or a keyring entry.

## Per-host settings

chezmoi derives file modes from the `umask`. On a host with `umask 0002`, modes in `chezmoi diff` shift (644 to 664, 755 to 775) even though the source didn't change. Set `umask = 0o022` at the top level of that host's chezmoi config file. The `gh` config source is `private_config.yml`, so it stays mode 0600 on any `umask`.

Directories that hold credentials have the `private_` attribute in the source (`.claude`, `.config`, `.config/gh`, `.local`, `.local/share/gh`), so they're 0700 on every host regardless of `umask`. Other directories take the `umask` default, so a `umask 0002` host shows 775 versus 755 in `chezmoi diff` unless its chezmoi config sets `umask = 0o022`.

Mac-only trees (`Library`, `Application Support`, `.config/agent-safehouse`) appear in `home/.chezmoiignore`, so chezmoi skips them off macOS.

A host where agents commit sets `agentSigningIncludes = true` under `[data]` in its chezmoi config. That adds the `includeIf` blocks that make commits under `~/Code/github.com/tbhb-dev/` and `~/Code/scratch/` use the agent signing config file `agent-git-signing.gitconfig` under `~/.config` (the exact path is in `home/dot_gitconfig.tmpl`). Leave it unset on a host where the owner commits by hand, since those commits would sign with the agent key.

A host where bare short host names should resolve needs two keys under `[data]` in its chezmoi config. `sshShortHostPrefix` is a string and `sshShortHostPatterns` is a list of `ssh` `Host` patterns. `~/.ssh/config` then gets `Host <patterns>` with `Hostname <prefix>%h`, so `ssh ab01` connects to `<prefix>ab01` without waiting on a failing lookup of the short name. Set both keys. If either is missing, the template omits the block. The names live only in each host's own config, never in this repo.

To deter agent sessions from using the owner's account on some hosts, set two keys under `[data]` in the chezmoi config of each host where agents run. `sshAgentRefuseUser` is the account name and `sshAgentRefuseHosts` is a list of `ssh` host patterns, matched against the final host name. An exact name misses its spelling with a trailing dot, so list both or end a pattern with `*` when its prefix names only guarded hosts. `~/.ssh/config` then gets a `Match host` block at its end whose `exec` kills the `ssh` process for that user (with or without a `:style` suffix, or any user with a `%` token) on those hosts when `ssh` inherits a nonempty agent variable: `CLAUDECODE`, `CODEX_HOME` or `CODEX_THREAD_ID`. A startup file of `SHELL` that sets one without exporting it doesn't count. One that exports it does, and refuses the owner too. Without one of those, `ssh` behaves as before, including from editors, scheduled jobs and other `ssh` sessions. The check runs while `ssh` reads the file, and options on the command line can't skip it for a matching name. The account must be one plain name and each pattern plain letters, digits, `.`, `_`, `-`, `*` and `?`. Anything else stops the render, and empty host entries are dropped. It's a deterrent, not a control. The control is agents not holding the owner's key at all. Known gaps, kept as security debt: an agent without one of those variables (a scrubbed environment, a `tmux` server that drops them, a harness such as Antigravity with no verified variable, or an agent marked only by a `TBHB_AGENT*` variable, which nothing sets today), `-F`, an IP address, a `ProxyCommand` or canonical name that reaches the host under another name, a `SHELL` that can't run the command, a later `Hostname` or `User` rule in the system config, an account lookup that ignores case, and an agent variable set to an empty string. An agent can't use a user name that contains `%` on those hosts, including a token that would expand to the ops account. A `tmux` pane opened before a reload keeps `CODEX_THREAD_ID` from a server an agent started, and is refused until it restarts. The 1Password checks in `.zprofile`, `~/.ssh/config` and `tbhb-ssh-sign` don't check `CODEX_THREAD_ID`. A host where agents run but the keys aren't set has no guard. Set both keys. If either is missing, the template omits the block. The values live only in each host's own config, never in this repo.

To drop exact entries from a host's live `permissions.allow` list, set `removeAllowEntries` under `[data]` in that host's chezmoi config. The value is a list of strings. On apply, `modify_settings.json.tmpl` removes those entries and changes nothing else. With the key unset, it leaves the list alone. The entry text lives only in each host's own config, never in this repo.

To make zsh a Linux host's login shell, run `sudo -n chsh -s /usr/bin/zsh <user>`. Plain `chsh` asks for the account password, which fails on accounts without a usable password.

## Multi-platform considerations

This repo targets three environments: macOS (Apple Silicon), Ubuntu, and devcontainers. Use chezmoi's templating to handle platform differences:

- **OS detection:** `{{ if $isDarwin }}` / `{{ if $isLinux }}`
- **Detecting devcontainers:** `{{ if $isDevcontainer }}` (checks the `REMOTE_CONTAINERS` and `CODESPACES` environment variables)
- **Homebrew paths:** use the `$brewPrefix` variable, not hardcoded paths
- **macOS-only blocks:** 1Password SSH agent, Docker Desktop, `Ghostty` and Zed `tmux` sockets, Tailscale alias, Homebrew `coreutils` in `PATH`
- **Skipped in devcontainers:** `OP_ACCOUNT`, `SSH_AUTH_SOCK`

## Key configuration details

- **Prompt:** `starship`, installed via mise (not Homebrew)
- **Editor:** `nvim`, set in `.zshenv`
- **SSH:** 1Password agent (`SSH_AUTH_SOCK`)
- **Runtime management:** mise (polyglot version manager)
- **Docker:** binaries symlinked from Docker.app to `~/.docker/bin`, completions from `~/.docker/completions`
- **Terminal multiplexing:** `tmux` with per-terminal sockets (`Ghostty`, Zed, VS Code)
- **`tmux` status line:** hand-written on every OS, using native `status-left`, `status-right` and `window-status-*` formats in `.tmux.conf` (`Monokai` Pro pills, refreshed every second). The processor and memory segments are small scripts under `~/.config/tmux-status`, called through `#()`. The repo dropped `tmux-powerline`, and `.chezmoiremove` clears its config directory and plugin clone from hosts that still have them.
- **`PATH`:** `coreutils`, `sed`, `tar` and `curl` from Homebrew come before the macOS defaults (on macOS only)
