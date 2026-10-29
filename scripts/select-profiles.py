#!/usr/bin/env python3
"""Interactive checkbox UI to pick which preset profiles to keep."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_preset(path: Path) -> tuple[str, dict, dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data:
        raise SystemExit("error: empty preset")
    # First (usually only) device key
    dev_id = next(iter(data.keys()))
    device = data[dev_id]
    if not isinstance(device, dict):
        raise SystemExit("error: invalid device in preset")
    profiles = device.get("profiles") or {}
    if not isinstance(profiles, dict) or not profiles:
        raise SystemExit("error: preset has no profiles")
    return dev_id, device, profiles


def render(items: list[tuple[str, str, bool]]) -> None:
    # Clear screen for a single focused view
    sys.stdout.write("\033[H\033[J")
    print("==============================================")
    print("  Select profiles to enable")
    print("==============================================")
    print()
    print("  Toggle: enter number(s)  e.g. 1 3 5")
    print("  a = all   n = none   Enter = confirm")
    print()
    for i, (_pid, name, on) in enumerate(items, start=1):
        mark = "x" if on else " "
        print(f"  [{mark}] {i:2d}) {name}")
    print()
    selected = sum(1 for *_, on in items if on)
    print(f"  Selected: {selected}/{len(items)}")
    print()


def interactive_select(profiles: dict) -> list[str]:
    items = [(pid, str((p or {}).get("name") or pid), True) for pid, p in profiles.items()]
    while True:
        render(items)
        try:
            raw = input("Toggle / confirm: ").strip()
        except EOFError:
            raw = ""
        if raw == "":
            chosen = [pid for pid, _n, on in items if on]
            if not chosen:
                print("Select at least one profile.")
                input("Press Enter...")
                continue
            return chosen
        if raw.lower() == "a":
            items = [(pid, name, True) for pid, name, _ in items]
            continue
        if raw.lower() == "n":
            items = [(pid, name, False) for pid, name, _ in items]
            continue
        for token in raw.replace(",", " ").split():
            if not token.isdigit():
                continue
            idx = int(token) - 1
            if 0 <= idx < len(items):
                pid, name, on = items[idx]
                items[idx] = (pid, name, not on)


def filter_preset(data: dict, selected: set[str]) -> dict:
    out = json.loads(json.dumps(data))  # deep copy
    for _dev_id, device in out.items():
        if not isinstance(device, dict):
            continue
        profiles = device.get("profiles") or {}
        if not isinstance(profiles, dict):
            continue
        device["profiles"] = {k: v for k, v in profiles.items() if k in selected}

        # Drop schedule entries that point at removed profiles
        sched = device.get("scheduler") or {}
        if isinstance(sched, dict):
            schedule = sched.get("schedule")
            if isinstance(schedule, dict):
                cleaned = {t: p for t, p in schedule.items() if p in selected}
                if cleaned:
                    sched["schedule"] = cleaned
                    device["scheduler"] = sched
                else:
                    device.pop("scheduler", None)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", required=True, help="Full presets/*/sdrs.json")
    ap.add_argument("--output", required=True, help="Write filtered preset JSON here")
    ap.add_argument(
        "--selected-file",
        help="Also write newline-separated selected profile ids",
    )
    ap.add_argument(
        "--noninteractive",
        action="store_true",
        help="Keep all profiles (no UI)",
    )
    ap.add_argument(
        "--only",
        help="Comma-separated profile ids (skip UI)",
    )
    args = ap.parse_args()

    preset_path = Path(args.preset)
    if not preset_path.is_file():
        print(f"error: preset not found: {preset_path}", file=sys.stderr)
        return 1

    data = json.loads(preset_path.read_text(encoding="utf-8"))
    _dev_id, _device, profiles = load_preset(preset_path)

    if args.only:
        selected = [s.strip() for s in args.only.split(",") if s.strip()]
        missing = [s for s in selected if s not in profiles]
        if missing:
            print(f"error: unknown profile ids: {', '.join(missing)}", file=sys.stderr)
            return 1
    elif args.noninteractive:
        selected = list(profiles.keys())
    else:
        selected = interactive_select(profiles)

    selected_set = set(selected)
    filtered = filter_preset(data, selected_set)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(filtered, indent=2) + "\n", encoding="utf-8")

    if args.selected_file:
        Path(args.selected_file).write_text("\n".join(selected) + "\n", encoding="utf-8")

    # Summary on stderr so stdout stays clean if piped; we print to stdout for humans
    names = []
    for pid in selected:
        names.append(str((profiles.get(pid) or {}).get("name") or pid))
    print(f"Kept {len(selected)} profile(s): " + ", ".join(names))
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
