#!/usr/bin/env python3
"""Mechanical guards for the 2026-11-08 current-state rule.

Wired in ~/.claude/settings.json for every Claude session as tony:
  PreToolUse Bash         block agent commits carrying Signed-off-by or Co-authored-by
  PreToolUse SendMessage  block a status claim with no evidence
  PreToolUse Write|Edit   memory files need a Source: line; new Open.md items
                          need "Decisions checked:"
  Stop                    block a final reply whose status claims carry no evidence

Evidence means: a git sha (7 to 40 hex), a PR or issue number (#N), a path to
a log or output, inline `code`, or attribution ("ops says").
Blocks exit 2 with the reason on stderr.
"""
import json
import re
import sys

CLAIM = re.compile(
    r"\b(?:is|are|was|were|now|already|has been|have been)\s+"
    r"(?:done|applied|merged|shipped|deployed|live|fixed|complete|completed|"
    r"installed|running|verified|in place|started)\b"
    r"|\b(?:shipped|merged|applied|deployed|landed|rolled out)\b",
    re.IGNORECASE,
)
EVIDENCE = re.compile(
    r"\b[0-9a-f]{7,40}\b|#\d+|\bsays\b|\bsaid\b|\breports?\b|\.log\b|`[^`]+`"
    r"|\boutput\b|\bread-back\b|\bnot (?:done|applied|merged)\b",
    re.IGNORECASE,
)
TRAILER = re.compile(r"(?i)(signed-off-by|co-authored-by)\s*:")
MEMORY_DIR = "/.claude/projects/"
OPEN_MD = "/Needs tbhb/Open.md"


RULE = """CURRENT-STATE RULE (tbhb 2026-11-08, enforced by ~/.claude/hooks/state-guard.py):
1. Primary sources beat notes: git main and merged PRs, a live read of the host or service, and Needs tbhb/Decisions/ (/Users/tony/Obsidian/tbhb-dev/Needs tbhb/Decisions/ on usdholt04). Memory, drafts, briefs and earlier messages are leads. Check one before acting on it or relaying it.
2. A status claim (done, applied, merged, shipped, deployed, started, blocked) carries its artifact: PR# and sha, merge sha, command output or log path. Otherwise attribute it ("ops says") or mark it unverified. SendMessage and final replies that break this are blocked.
3. Before saying something waits on tbhb, grep Decisions. A new Open.md item needs "Decisions checked: <terms>".
4. Agent commits carry NO Signed-off-by or Co-authored-by. `git commit -s` and --signoff are blocked.
5. Memory files need a "Source:" line naming the primary source.
6. Report a missed ETA before anyone asks. Approvals still go only through coord running tbhb-approve."""

def block(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(2)


def unevidenced(text: str) -> list[str]:
    """Sentences (or lines) with a status claim and no evidence."""
    bad = []
    for chunk in re.split(r"(?<=[.!?])\s+|\n", text):
        if CLAIM.search(chunk) and not EVIDENCE.search(chunk):
            bad.append(chunk.strip()[:160])
    return bad


def git_commits(cmd: str) -> list[str]:
    return [seg for seg in re.split(r"&&|\|\||;|\|", cmd) if re.search(r"\bgit\b[^\n]*\bcommit\b", seg)]


CWD = None


def signoff_on(cwd) -> bool:
    import subprocess
    try:
        r = subprocess.run(["git", "config", "--get", "--type=bool", "commit.signoff"],
                           cwd=cwd or None, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.stdout.strip() == "true"


def check_bash(cmd: str) -> None:
    for seg in git_commits(cmd):
        if TRAILER.search(seg) or re.search(r"--signoff\b|--trailer[= ]+['\"]?(?i:signed-off-by|co-authored-by)", seg):
            block("state-guard: agent commits carry no Signed-off-by or Co-authored-by "
                  "(every repo's AGENTS.md). Remove it.")
        after = seg.split("commit", 1)[1]
        # short flags only, not inside -m strings
        stripped = re.sub(r"(['\"]).*?\1", "", after)
        if re.search(r"(?:^|\s)-(?!-)[a-zA-Z]*s[a-zA-Z]*(?=\s|$)", stripped):
            block("state-guard: `git commit -s` adds Signed-off-by; agent commits carry none.")
        if "--no-signoff" not in seg and signoff_on(CWD):
            block("state-guard: git config commit.signoff is true here (~/.gitconfig), so this "
                  "commit would get Signed-off-by. Add --no-signoff.")


def check_send(msg: str) -> None:
    bad = unevidenced(msg)
    if bad:
        block("state-guard: status claim without evidence. Add the PR#/sha, merge sha, "
              "command output or log path, or attribute it ('ops says ...'). Offending: "
              + " | ".join(bad[:3]))


def check_write(tool: str, inp: dict) -> None:
    path = inp.get("file_path", "")
    new = inp.get("content") if tool == "Write" else inp.get("new_string", "")
    new = new or ""
    if MEMORY_DIR in path and "/memory/" in path and path.endswith(".md") \
            and not path.endswith("/MEMORY.md") and tool == "Write":
        if not re.search(r"(?im)^\**source:?\**", new):
            block("state-guard: memory files need a 'Source:' line naming the primary source "
                  "(tbhb's message with date, PR/sha, file path, or live read).")
    if path.endswith(OPEN_MD):
        new_items = re.findall(r"(?m)^- \*\*.*$", new)
        old = inp.get("old_string", "") if tool == "Edit" else ""
        added = [i for i in new_items if i not in old]
        if added and "Decisions checked:" not in new:
            block("state-guard: a new Open item needs 'Decisions checked: <grep terms>' "
                  "showing you grepped Needs tbhb/Decisions first.")


def last_assistant_text(path: str) -> str:
    text = ""
    try:
        with open(path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") == "user" and isinstance(d.get("message", {}).get("content"), str):
                    text = ""
                if d.get("type") != "assistant":
                    continue
                for c in d.get("message", {}).get("content", []):
                    if isinstance(c, dict) and c.get("type") == "text":
                        text = c["text"]
    except OSError:
        return ""
    return text


def main() -> None:
    data = json.load(sys.stdin)
    event = data.get("hook_event_name")
    if event == "SessionStart":
        print(RULE)
        return
    if event == "Stop":
        if data.get("stop_hook_active"):
            return
        msg = data.get("last_assistant_message") or last_assistant_text(data.get("transcript_path", ""))
        bad = unevidenced(msg)
        if bad:
            print(json.dumps({"decision": "block", "reason":
                "state-guard: your reply makes status claims without evidence. Add the "
                "PR#/sha, command output or log path, attribute them ('ops says'), or "
                "say they're unverified: " + " | ".join(bad[:3])}))
        return
    tool = data.get("tool_name", "")
    inp = data.get("tool_input", {}) or {}
    global CWD
    CWD = data.get("cwd")
    if tool == "Bash":
        check_bash(inp.get("command", ""))
    elif tool == "SendMessage":
        check_send(str(inp.get("message", "")))
    elif tool in ("Write", "Edit"):
        check_write(tool, inp)


if __name__ == "__main__":
    main()
