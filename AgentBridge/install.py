#!/usr/bin/env python3
"""Install / remove Notch agent hooks for Claude Code, Codex, Antigravity and OpenCode.

    python3 install.py            install (idempotent; backs up every file it edits)
    python3 install.py status     show what is installed
    python3 install.py uninstall  remove only the Notch entries

Agent Hub needs nothing: Notch reads its job files read-only.
"""
import json
import shutil
import sys
import time
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
ROOT = HOME / ".notch-agents"
BRIDGE = ROOT / "bin" / "notch-agent-bridge"
MARK = "notch-agent-bridge"
CMD = 'python3 "$HOME/.notch-agents/bin/notch-agent-bridge"'

CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
CODEX_HOOKS = HOME / ".codex" / "hooks.json"
ANTIGRAVITY_ROOTS = [HOME / ".gemini" / d for d in ("antigravity", "antigravity-cli", "antigravity-ide")]
OPENCODE_PLUGIN = HOME / ".config" / "opencode" / "plugin" / "notch-agents.js"

CLAUDE_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd", "PermissionRequest"]
CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "PermissionRequest"]
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PermissionRequest"}


def load(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, path.with_name(f"{path.name}.notch-backup-{time.strftime('%Y%m%d-%H%M%S')}"))
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def strip_claude_style(hooks):
    """Remove our handlers from a Claude-format hooks map, keep everything else."""
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            kept = [h for h in g.get("hooks", []) if MARK not in h.get("command", "")]
            if kept:
                groups.append({**g, "hooks": kept})
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    return hooks


def add_claude_style(hooks, platform, events):
    for event in events:
        handler = {"type": "command", "command": f"{CMD} {platform} {event}",
                   "timeout": 600 if event == "PermissionRequest" else 10}
        group = {"hooks": [handler]}
        if event in TOOL_EVENTS:
            group = {"matcher": "*", **group}
        hooks.setdefault(event, []).append(group)
    return hooks


def install_claude(remove=False):
    data = load(CLAUDE_SETTINGS)
    hooks = strip_claude_style(data.get("hooks", {}))
    if not remove:
        add_claude_style(hooks, "claude", CLAUDE_EVENTS)
    data["hooks"] = hooks
    if not hooks:
        data.pop("hooks")
    save(CLAUDE_SETTINGS, data)


def install_codex(remove=False):
    if not (HOME / ".codex").exists():
        return "skipped (no ~/.codex)"
    data = load(CODEX_HOOKS)
    hooks = strip_claude_style(data.get("hooks", {}))
    if not remove:
        add_claude_style(hooks, "codex", CODEX_EVENTS)
    data["hooks"] = hooks
    save(CODEX_HOOKS, data)
    return "ok — Codex asks you to trust new hooks once (review them in Codex)"


def install_antigravity(remove=False):
    done = []
    for root in ANTIGRAVITY_ROOTS:
        if not root.exists():
            continue
        path = root / "hooks.json"
        data = load(path)
        data.pop("notch-agents", None)
        if not remove:
            run = lambda e: {"type": "command", "command": f"{CMD} antigravity {e}", "timeout": 5}
            data["notch-agents"] = {
                "enabled": True,
                "PreInvocation": [run("PreInvocation")],
                "PostToolUse": [{"matcher": "*", "hooks": [run("PostToolUse")]}],
                "Stop": [run("Stop")],
            }
        if data:
            save(path, data)
        elif path.exists():
            path.unlink()
        done.append(root.name)
    return ", ".join(done) or "skipped (no ~/.gemini/antigravity*)"


def install_opencode(remove=False):
    if remove:
        OPENCODE_PLUGIN.unlink(missing_ok=True)
        return "removed"
    if not (HOME / ".config" / "opencode").exists():
        return "skipped (no ~/.config/opencode)"
    OPENCODE_PLUGIN.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "opencode-notch-plugin.js", OPENCODE_PLUGIN)
    return "ok"


def install_bridge():
    for d in ("bin", "sessions", "requests", "responses", "platforms"):
        (ROOT / d).mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copy2(HERE / "notch-agent-bridge.py", BRIDGE)
    BRIDGE.chmod(0o755)


def status():
    claude = MARK in json.dumps(load(CLAUDE_SETTINGS).get("hooks", {}))
    codex = MARK in json.dumps(load(CODEX_HOOKS)) if CODEX_HOOKS.exists() else False
    ag = [r.name for r in ANTIGRAVITY_ROOTS if "notch-agents" in load(r / "hooks.json")] if any(r.exists() for r in ANTIGRAVITY_ROOTS) else []
    print(f"bridge       {'installed' if BRIDGE.exists() else 'missing'}  {BRIDGE}")
    print(f"Claude Code  {'installed' if claude else 'not installed'}  {CLAUDE_SETTINGS}")
    print(f"Codex        {'installed' if codex else 'not installed'}  {CODEX_HOOKS}")
    print(f"Antigravity  {', '.join(ag) if ag else 'not installed'}")
    print(f"OpenCode     {'installed' if OPENCODE_PLUGIN.exists() else 'not installed'}  {OPENCODE_PLUGIN}")
    print("Agent Hub    read-only (no install needed)")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "install"
    if action == "status":
        return status()
    remove = action == "uninstall"
    if not remove:
        install_bridge()
    install_claude(remove)
    print("Claude Code ", "removed" if remove else "ok")
    print("Codex       ", install_codex(remove))
    print("Antigravity ", install_antigravity(remove))
    print("OpenCode    ", install_opencode(remove))
    print("Restart running agent sessions to pick up the hooks." if not remove else "Done.")


if __name__ == "__main__":
    main()
