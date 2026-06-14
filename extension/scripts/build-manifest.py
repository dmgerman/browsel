#!/usr/bin/env python3
"""Generate manifest.json from config.json.

config.json is the SINGLE SOURCE OF TRUTH for this extension:

  - config.extension     : the static MV3 manifest infrastructure
                           (name, version, permissions, background, etc.)
  - config.menus         : context-menu / keyboard-command bindings.
                           Each entry's optional `command` block is collected
                           into manifest.commands.
  - config.contentScripts: declarative content_scripts (matches/js/run_at).
  - config.handlers      : runtime-only, ignored here.

This script reads config.json and writes manifest.json containing only
the keys Chrome cares about.  Run it any time config.json changes; the
Makefile wires this in for you (`make manifest`, run by `make lint`).
"""

import json
import sys
from pathlib import Path

EXT_DIR     = Path(__file__).resolve().parent.parent
CONFIG_PATH = EXT_DIR / "config.json"
# Output path is overridable from the Makefile (and defaults to the
# build dir).  Keeps the source tree free of generated files.
OUTPUT_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else (EXT_DIR / "build" / "manifest.json")

# Chrome's manifest.json is strict: no // comments AND no unknown
# top-level keys (it warns on `_comment` and friends).  We can't bake
# a "do not edit" notice into the manifest itself; the build-output
# directory is gitignored, and the only way to produce one is
# `make build`, which is a clear enough signpost.


def die(msg: str) -> "NoReturn":
    sys.stderr.write(f"build-manifest: {msg}\n")
    sys.exit(1)


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        die("missing config.json")
    try:
        return json.loads(CONFIG_PATH.read_text())
    except json.JSONDecodeError as e:
        die(f"config.json is not valid JSON: {e}")


def validate_content_scripts(scripts: list) -> None:
    if not isinstance(scripts, list):
        die("config.contentScripts must be an array")
    for i, s in enumerate(scripts):
        loc = f"contentScripts[{i}]"
        if not isinstance(s, dict):
            die(f"{loc} must be an object")
        if not isinstance(s.get("matches"), list) or not s["matches"]:
            die(f"{loc}.matches must be a non-empty array")
        if not isinstance(s.get("js"), list) or not s["js"]:
            die(f"{loc}.js must be a non-empty array")
        for j in s["js"]:
            if not (EXT_DIR / j).exists():
                die(f"{loc}.js references missing file: {j}")


def collect_commands(menus: list) -> dict:
    """Pull each menu's `command` block up into manifest.commands."""
    commands: dict = {}
    for i, m in enumerate(menus):
        cmd = m.get("command")
        if not cmd:
            continue
        if not isinstance(cmd, dict):
            die(f"menus[{i}].command must be an object")
        name = cmd.get("name")
        if not name:
            die(f"menus[{i}].command.name is required")
        if name in commands:
            die(f"duplicate command name across menus: {name!r}")
        # Strip our `name` field; the rest is Chrome's command spec.
        entry = {k: v for k, v in cmd.items() if k != "name"}
        commands[name] = entry
    return commands


def main() -> None:
    cfg = load_config()

    if "extension" not in cfg or not isinstance(cfg["extension"], dict):
        die("config.json must contain an `extension` object")

    menus = cfg.get("menus", [])
    if not isinstance(menus, list):
        die("config.menus must be an array")

    scripts = cfg.get("contentScripts", [])
    validate_content_scripts(scripts)

    # Lead with the notice so anyone who opens manifest.json sees it first.
    # Chrome ignores underscore-prefixed top-level keys.
    manifest = dict(cfg["extension"])

    commands = collect_commands(menus)
    if commands:
        manifest["commands"] = commands
    if scripts:
        manifest["content_scripts"] = scripts

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    )
    try:
        display = OUTPUT_PATH.relative_to(EXT_DIR)
    except ValueError:
        display = OUTPUT_PATH
    print(
        f"wrote {display} "
        f"({len(commands)} commands, {len(scripts)} content_scripts)"
    )


if __name__ == "__main__":
    main()
