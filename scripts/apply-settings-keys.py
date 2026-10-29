#!/usr/bin/env python3
"""Merge top-level keys into OpenWebRX+ settings.json (MQTT, SondeHub, services, …)."""
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


def find_settings(var_dir: Path) -> Optional[Path]:
    for p in (var_dir / "settings.json", var_dir / "openwebrx" / "settings.json"):
        if p.is_file():
            return p
    if var_dir.is_dir():
        try:
            paths = list(var_dir.rglob("settings.json"))
        except PermissionError:
            out = subprocess.check_output(
                ["sudo", "find", str(var_dir), "-name", "settings.json"], text=True
            )
            paths = [Path(x.strip()) for x in out.splitlines() if x.strip()]
        for p in sorted(set(paths)):
            try:
                data = json.loads(read_text(p))
            except Exception:
                continue
            if isinstance(data, dict) and "sdrs" in data:
                return p
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--var-dir", required=True)
    ap.add_argument("--patch", required=True, help="JSON object of top-level settings keys")
    args = ap.parse_args()

    patch_path = Path(args.patch)
    if not patch_path.is_file():
        print(f"error: patch not found: {patch_path}", file=sys.stderr)
        return 1
    patch = json.loads(patch_path.read_text(encoding="utf-8"))
    if not isinstance(patch, dict):
        print("error: patch must be a JSON object", file=sys.stderr)
        return 1

    var_dir = Path(args.var_dir)
    settings_path = find_settings(var_dir)
    if settings_path is None:
        settings_path = var_dir / "settings.json"
        settings: dict = {"version": 8, "sdrs": {}}
    else:
        settings = json.loads(read_text(settings_path))
        if not isinstance(settings, dict):
            print(f"error: invalid settings at {settings_path}", file=sys.stderr)
            return 1

    for k, v in patch.items():
        settings[k] = v

    write_text(settings_path, json.dumps(settings, indent=2) + "\n")
    print(f"updated keys in {settings_path}: " + ", ".join(sorted(patch.keys())))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130) from None
