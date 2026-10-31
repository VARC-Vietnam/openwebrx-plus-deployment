#!/usr/bin/env python3
"""Convert an rtl_sdr OpenWebRX preset to type rtl_tcp with remote=host:port."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def convert(sdrs: dict, remote: str) -> dict:
    out: dict = {}
    for key, dev in sdrs.items():
        if not isinstance(dev, dict):
            continue
        entry = dict(dev)
        entry["type"] = "rtl_tcp"
        entry["remote"] = remote
        entry.pop("rtltcp_compat", None)
        # Connection port lives in remote=IP:Port; drop USB-style rtl_tcp publish port.
        entry.pop("port", None)
        if not entry.get("name"):
            entry["name"] = "RTL-SDR (rtl_tcp)"
        elif "rtl_tcp" not in str(entry["name"]).lower():
            entry["name"] = f"{entry['name']} (rtl_tcp)"
        out[key] = entry
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, help="Input sdrs.json (rtl_sdr profiles)")
    ap.add_argument("--output", required=True, help="Output sdrs.json (rtl_tcp)")
    ap.add_argument(
        "--remote",
        required=True,
        help="Remote rtl_tcp endpoint as host:port (e.g. 192.168.1.50:1234)",
    )
    args = ap.parse_args()

    remote = args.remote.strip()
    if ":" not in remote or remote.startswith(":") or remote.endswith(":"):
        print(f"error: --remote must be host:port, got {remote!r}", file=sys.stderr)
        return 1

    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data:
        print("error: input must be a non-empty sdrs object", file=sys.stderr)
        return 1

    converted = convert(data, remote)
    if not converted:
        print("error: no devices to convert", file=sys.stderr)
        return 1

    Path(args.output).write_text(json.dumps(converted, indent=2) + "\n", encoding="utf-8")
    print(f"rtl_tcp remote={remote} devices={','.join(sorted(converted))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
