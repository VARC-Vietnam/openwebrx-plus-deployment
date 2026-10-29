#!/usr/bin/env python3
"""Ensure /etc/openwebrx bands*.json include a 400–406 MHz sonde dial for background decode."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SONDE_BAND = {
    "name": "Radiosonde 400 MHz",
    "lower_bound": 400000000,
    "upper_bound": 406000000,
    "frequencies": {
        "sonde-rs41": 403000000,
        "sonde-dfm9": 403000000,
        "sonde-dfm17": 403000000,
        "sonde-m10": 403000000,
        "sonde-m20": 403000000,
        "sonde-mts01": 403000000,
    },
}


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except PermissionError:
        return subprocess.check_output(["sudo", "cat", str(path)], text=True)


def write_text(path: Path, data: str) -> None:
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
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or ""
    if user:
        subprocess.call(["sudo", "chown", f"{user}:{user}", str(path)])


def ensure_file(path: Path, modes: set[str]) -> bool:
    if not path.is_file():
        # Create a minimal bands file with just the sonde band
        freqs = {m: SONDE_BAND["frequencies"][m] for m in modes if m in SONDE_BAND["frequencies"]}
        if not freqs:
            freqs = {"sonde-rs41": 403000000}
        band = dict(SONDE_BAND)
        band["frequencies"] = freqs
        write_text(path, json.dumps([band], indent=2) + "\n")
        return True

    data = json.loads(read_text(path))
    if not isinstance(data, list):
        print(f"error: {path} is not a band list", file=sys.stderr)
        return False

    changed = False
    found = None
    for band in data:
        if not isinstance(band, dict):
            continue
        lo = band.get("lower_bound")
        hi = band.get("upper_bound")
        if isinstance(lo, (int, float)) and isinstance(hi, (int, float)) and lo <= 403e6 <= hi:
            found = band
            break
        if str(band.get("name", "")).lower().startswith("radiosonde"):
            found = band
            break

    if found is None:
        band = dict(SONDE_BAND)
        band["frequencies"] = {
            m: SONDE_BAND["frequencies"][m] for m in modes if m in SONDE_BAND["frequencies"]
        } or {"sonde-rs41": 403000000}
        data.append(band)
        changed = True
        found = band
    else:
        freqs = found.get("frequencies")
        if not isinstance(freqs, dict):
            freqs = {}
            found["frequencies"] = freqs
            changed = True
        for m in modes:
            if m in SONDE_BAND["frequencies"] and freqs.get(m) != SONDE_BAND["frequencies"][m]:
                freqs[m] = SONDE_BAND["frequencies"][m]
                changed = True

    if changed:
        write_text(path, json.dumps(data, indent=2) + "\n")
    return changed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--etc-dir", required=True, help="Host path mapped to /etc/openwebrx")
    ap.add_argument(
        "--modes",
        default="sonde-rs41",
        help="Comma-separated sonde mode ids to ensure in the bandplan",
    )
    args = ap.parse_args()
    etc = Path(args.etc_dir)
    modes = {m.strip() for m in args.modes.split(",") if m.strip()}
    etc.mkdir(parents=True, exist_ok=True)

    targets = [etc / "bands.json"]
    for n in (1, 2, 3):
        p = etc / f"bands-r{n}.json"
        if p.is_file():
            targets.append(p)

    any_changed = False
    for path in targets:
        if ensure_file(path, modes):
            print(f"updated: {path}")
            any_changed = True
        else:
            print(f"ok: {path}")
    if not any_changed:
        print("bandplan already contains sonde dials")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
