#!/usr/bin/env python3
"""Replace OpenWebRX+ sdrs entirely with our preset (no Airspy/SDRPlay leftovers)."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except PermissionError:
        return subprocess.check_output(["sudo", "cat", str(path)], text=True)


def write_text(path: Path, data: str) -> None:
    """Write file; fall back to sudo tee when not writable."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data, encoding="utf-8")
        return
    except PermissionError:
        pass

    subprocess.check_call(["sudo", "mkdir", "-p", str(path.parent)])
    subprocess.run(
        ["sudo", "tee", str(path)],
        input=data,
        text=True,
        stdout=subprocess.DEVNULL,
        check=True,
    )
    # Make host user able to edit next time; container can still read
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or ""
    if user:
        subprocess.call(["sudo", "chown", f"{user}:{user}", str(path)])


def find_settings(var_dir: Path) -> Optional[Path]:
    candidates = [
        var_dir / "settings.json",
        var_dir / "config.json",
        var_dir / "openwebrx" / "settings.json",
    ]
    for p in candidates:
        if p.is_file():
            return p
    if var_dir.is_dir():
        try:
            paths = list(var_dir.rglob("settings.json")) + list(var_dir.glob("*.json"))
        except PermissionError:
            # List via sudo find
            out = subprocess.check_output(
                ["sudo", "find", str(var_dir), "-name", "settings.json"],
                text=True,
            )
            paths = [Path(line.strip()) for line in out.splitlines() if line.strip()]
        for p in sorted(set(paths)):
            try:
                data = json.loads(read_text(p))
            except (OSError, json.JSONDecodeError, subprocess.CalledProcessError):
                continue
            if isinstance(data, dict) and "sdrs" in data:
                return p
    return None


def load_json(path: Path) -> dict:
    return json.loads(read_text(path))


def profile_names(sdrs: dict) -> list:
    names = []
    for dev in sdrs.values():
        if not isinstance(dev, dict):
            continue
        profiles = dev.get("profiles") or {}
        if isinstance(profiles, dict):
            for p in profiles.values():
                if isinstance(p, dict) and p.get("name"):
                    names.append(str(p["name"]))
    return names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--var-dir", required=True, help="Host path mapped to /var/lib/openwebrx")
    ap.add_argument("--preset", required=True, help="Path to presets/*/sdrs.json (or filtered)")
    ap.add_argument(
        "--background",
        help="Optional background.json (defaults to <preset-dir>/background.json)",
    )
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    var_dir = Path(args.var_dir)
    preset_path = Path(args.preset)
    if not preset_path.is_file():
        print(f"error: preset not found: {preset_path}", file=sys.stderr)
        return 1

    preset = json.loads(preset_path.read_text(encoding="utf-8"))
    if not isinstance(preset, dict) or not preset:
        print("error: preset must be a non-empty object of SDR devices", file=sys.stderr)
        return 1

    settings_path = find_settings(var_dir)
    if settings_path is None:
        settings_path = var_dir / "settings.json"
        settings = {"version": 8}
        created = True
        old_keys = []
    else:
        settings = load_json(settings_path)
        if not isinstance(settings, dict):
            print(f"error: invalid settings at {settings_path}", file=sys.stderr)
            return 1
        created = False
        old = settings.get("sdrs") if isinstance(settings.get("sdrs"), dict) else {}
        old_keys = list(old.keys())

    new_sdrs = {}
    for key, dev in preset.items():
        if not isinstance(dev, dict):
            continue
        entry = dict(dev)
        entry["enabled"] = True
        new_sdrs[key] = entry

    if not new_sdrs:
        print("error: preset produced no devices", file=sys.stderr)
        return 1

    settings["sdrs"] = new_sdrs

    # Optional background decoding
    if args.background:
        background_path = Path(args.background)
    else:
        background_path = preset_path.parent / "background.json"
    bg_keys = []
    if background_path.is_file():
        background = json.loads(background_path.read_text(encoding="utf-8"))
        if isinstance(background, dict):
            for k, v in background.items():
                settings[k] = v
                bg_keys.append(k)

    names = profile_names(new_sdrs)
    payload = json.dumps(settings, indent=2) + "\n"

    if args.dry_run:
        print(
            json.dumps(
                {
                    "target": str(settings_path),
                    "profiles": names,
                    "background": {k: settings.get(k) for k in bg_keys},
                },
                indent=2,
            )
        )
        return 0

    write_text(settings_path, payload)

    action = "created" if created else "updated"
    print(f"{action}: {settings_path}")
    dropped = [k for k in old_keys if k not in new_sdrs]
    if dropped:
        print("removed devices: " + ", ".join(dropped))
    print("devices: " + ", ".join(sorted(new_sdrs.keys())))
    print(f"profiles ({len(names)}): " + ", ".join(names))
    if bg_keys:
        print(
            "background: services_enabled={0} decoders={1}".format(
                settings.get("services_enabled"),
                settings.get("services_decoders"),
            )
        )
    for dev_id, dev in new_sdrs.items():
        sched = (dev or {}).get("scheduler") or {}
        if isinstance(sched, dict) and sched.get("schedule"):
            print(
                "schedule ({0}): always-on={1} services={2} {3}".format(
                    dev_id,
                    (dev or {}).get("always-on"),
                    (dev or {}).get("services"),
                    sched.get("schedule"),
                )
            )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130) from None
