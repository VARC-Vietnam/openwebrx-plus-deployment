#!/usr/bin/env python3
"""Replace OpenWebRX+ sdrs with our preset; drop Airspy / SDRPlay defaults."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DROP_TYPES = {"airspy", "airspyhf", "sdrplay", "sdrplay3"}
DROP_KEYS = {"airspy", "airspyhf", "sdrplay", "sdrplay3"}


def find_settings(var_dir: Path) -> Path | None:
    candidates = [
        var_dir / "settings.json",
        var_dir / "config.json",
        var_dir / "openwebrx" / "settings.json",
    ]
    for p in candidates:
        if p.is_file():
            return p
    # Fall back: first *.json that looks like OWRX settings
    if var_dir.is_dir():
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
        # First boot: write minimal settings containing only our SDRs.
        # OpenWebRX+ will fill remaining defaults on start / merge as needed.
        settings_path = var_dir / "settings.json"
        var_dir.mkdir(parents=True, exist_ok=True)
        settings: dict = {"version": 8, "sdrs": {}}
        created = True
    else:
        settings = load_json(settings_path)
        if not isinstance(settings, dict):
            print(f"error: invalid settings at {settings_path}", file=sys.stderr)
            return 1
        created = False

    sdrs = settings.get("sdrs")
    if not isinstance(sdrs, dict):
        sdrs = {}

    # Remove Airspy / SDRPlay (by key and by type)
    removed = []
    for key in list(sdrs.keys()):
        dev = sdrs.get(key) or {}
        dtype = str(dev.get("type", "")).lower()
        if key.lower() in DROP_KEYS or dtype in DROP_TYPES:
            removed.append(f"{key} ({dtype or 'unknown'})")
            del sdrs[key]

    # Replace / set devices from preset (RTL-SDR or RX-888 only)
    for key, dev in preset.items():
        if not isinstance(dev, dict):
            continue
        # Ensure enabled
        dev = dict(dev)
        dev.setdefault("enabled", True)
        sdrs[key] = dev

    settings["sdrs"] = sdrs

    if args.dry_run:
        print(json.dumps(settings.get("sdrs"), indent=2))
        return 0

    settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    action = "created" if created else "updated"
    print(f"{action}: {settings_path}")
    if removed:
        print("removed: " + ", ".join(removed))
    print("devices: " + ", ".join(sorted(sdrs.keys())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
