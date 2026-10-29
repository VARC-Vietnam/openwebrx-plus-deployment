#!/usr/bin/env python3
"""Replace OpenWebRX+ sdrs entirely with our preset (no Airspy/SDRPlay leftovers)."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional


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
        for p in sorted(var_dir.rglob("settings.json")):
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(data, dict) and "sdrs" in data:
                return p
        for p in sorted(var_dir.glob("*.json")):
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(data, dict) and "sdrs" in data:
                return p
    return None


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def profile_names(sdrs: dict) -> list[str]:
    names: list[str] = []
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
    ap.add_argument("--preset", required=True, help="Path to presets/*/sdrs.json")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    var_dir = Path(args.var_dir)
    preset_path = Path(args.preset)
    if not preset_path.is_file():
        print(f"error: preset not found: {preset_path}", file=sys.stderr)
        return 1

    preset = load_json(preset_path)
    if not isinstance(preset, dict) or not preset:
        print("error: preset must be a non-empty object of SDR devices", file=sys.stderr)
        return 1

    settings_path = find_settings(var_dir)
    if settings_path is None:
        settings_path = var_dir / "settings.json"
        var_dir.mkdir(parents=True, exist_ok=True)
        settings: dict = {"version": 8}
        created = True
        old_keys: list[str] = []
    else:
        settings = load_json(settings_path)
        if not isinstance(settings, dict):
            print(f"error: invalid settings at {settings_path}", file=sys.stderr)
            return 1
        created = False
        old = settings.get("sdrs") if isinstance(settings.get("sdrs"), dict) else {}
        old_keys = list(old.keys())

    # Full replace: only devices from our preset (drops airspy/sdrplay/defaults)
    new_sdrs: dict = {}
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
    names = profile_names(new_sdrs)

    if args.dry_run:
        print(json.dumps({"sdrs": new_sdrs, "profiles": names}, indent=2))
        return 0

    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")

    action = "created" if created else "updated"
    print(f"{action}: {settings_path}")
    dropped = [k for k in old_keys if k not in new_sdrs]
    if dropped:
        print("removed devices: " + ", ".join(dropped))
    print("devices: " + ", ".join(sorted(new_sdrs.keys())))
    print(f"profiles ({len(names)}): " + ", ".join(names))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
