#!/usr/bin/env python3
"""Interactive checkbox UI to pick which preset profiles to keep."""
from __future__ import annotations

import argparse
import curses
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


def profile_freq_hz(prof: dict) -> float:
    """Sort key: center_freq, else start_freq (Hz)."""
    if not isinstance(prof, dict):
        return float("inf")
    for key in ("center_freq", "start_freq"):
        val = prof.get(key)
        if isinstance(val, (int, float)):
            return float(val)
    return float("inf")


def format_freq(hz: float) -> str:
    if hz == float("inf"):
        return "—".rjust(12)
    if hz >= 1e9:
        return f"{hz / 1e9:8.3f} GHz"
    if hz >= 1e6:
        return f"{hz / 1e6:8.3f} MHz"
    if hz >= 1e3:
        return f"{hz / 1e3:8.3f} kHz"
    return f"{hz:8.0f} Hz"


def load_previous_selection(path: Path) -> set[str] | None:
    """Load previously selected profile ids from SELECTED_PROFILES.txt or filtered JSON."""
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return None
    # JSON: filtered sdrs.selected.json (device → profiles)
    if text.startswith("{"):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        ids: set[str] = set()
        if isinstance(data, dict):
            for device in data.values():
                if not isinstance(device, dict):
                    continue
                profiles = device.get("profiles") or {}
                if isinstance(profiles, dict):
                    ids.update(profiles.keys())
        return ids or None
    # Plain text: one profile id per line
    ids = {line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")}
    return ids or None


def sorted_profile_items(profiles: dict, initial: set[str] | None = None) -> list[list]:
    """Build [pid, name, selected, freq_hz] sorted by frequency ascending.

    If initial is None (first install), all profiles start checked.
    If initial is a set (re-run), only those ids start checked; others stay off.
    """
    items = []
    for pid, p in profiles.items():
        name = str((p or {}).get("name") or pid)
        freq = profile_freq_hz(p or {})
        selected = True if initial is None else (pid in initial)
        items.append([pid, name, selected, freq])
    items.sort(key=lambda row: (row[3], row[1].lower()))
    return items


def interactive_select_curses(stdscr, items: list[list]) -> list[str] | None:
    """
    items: list of [pid, name, selected:bool, freq_hz]
    Returns list of selected pids, or None if cancelled.
    """
    curses.curs_set(0)
    stdscr.keypad(True)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        # 1: cursor on selected (bright)
        curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)
        # 2: selected (bright)
        curses.init_pair(2, curses.COLOR_WHITE, -1)
        # 3: header
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        # 4: unselected (dimmer)
        curses.init_pair(4, curses.COLOR_BLUE, -1)
        # 5: cursor on unselected
        curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_BLUE)

    cursor = 0
    scroll = 0
    status = ""

    while True:
        stdscr.erase()
        height, width = stdscr.getmaxyx()
        header_lines = 7
        footer_lines = 3
        list_h = max(1, height - header_lines - footer_lines)

        # Keep cursor visible
        if cursor < scroll:
            scroll = cursor
        elif cursor >= scroll + list_h:
            scroll = cursor - list_h + 1

        def put(y: int, x: int, text: str, attr=0) -> None:
            if y < 0 or y >= height:
                return
            stdscr.addnstr(y, x, text, max(0, width - x - 1), attr)

        put(0, 0, "=" * min(width - 1, 56), curses.color_pair(3) | curses.A_BOLD)
        put(1, 0, "  Select profiles to enable  (sorted by frequency)", curses.color_pair(3) | curses.A_BOLD)
        put(2, 0, "=" * min(width - 1, 56), curses.color_pair(3) | curses.A_BOLD)
        put(4, 0, "  ↑/↓ move   Space toggle   a all   n none")
        put(5, 0, "  Enter confirm   q cancel")

        for row in range(list_h):
            idx = scroll + row
            if idx >= len(items):
                break
            _pid, name, on, freq = items[idx]
            mark = "x" if on else " "
            freq_s = format_freq(freq)
            line = f"  [{mark}] {freq_s}  {name}"
            y = header_lines + row
            if idx == cursor and on:
                attr = curses.color_pair(1) | curses.A_BOLD
            elif idx == cursor:
                attr = curses.color_pair(5) | curses.A_BOLD
            elif on:
                # Selected: bright white + bold
                attr = curses.color_pair(2) | curses.A_BOLD
            else:
                # Unselected: dimmer
                attr = curses.color_pair(4) | curses.A_DIM
            put(y, 0, line.ljust(min(width - 1, 72)), attr)

        selected = sum(1 for item in items if item[2])
        put(height - 2, 0, f"  Selected: {selected}/{len(items)}   {status}")

        stdscr.refresh()
        key = stdscr.getch()
        status = ""

        if key in (curses.KEY_UP, ord("k")):
            cursor = (cursor - 1) % len(items)
        elif key in (curses.KEY_DOWN, ord("j")):
            cursor = (cursor + 1) % len(items)
        elif key in (curses.KEY_PPAGE,):
            cursor = max(0, cursor - list_h)
        elif key in (curses.KEY_NPAGE,):
            cursor = min(len(items) - 1, cursor + list_h)
        elif key in (curses.KEY_HOME,):
            cursor = 0
        elif key in (curses.KEY_END,):
            cursor = len(items) - 1
        elif key in (ord(" "), ord("x")):
            items[cursor][2] = not items[cursor][2]
        elif key in (ord("a"), ord("A")):
            for item in items:
                item[2] = True
            status = "all on"
        elif key in (ord("n"), ord("N")):
            for item in items:
                item[2] = False
            status = "all off"
        elif key in (ord("q"), 27):  # q or ESC
            return None
        elif key in (curses.KEY_ENTER, 10, 13):
            chosen = [pid for pid, _name, on, _freq in items if on]
            if not chosen:
                status = "select at least one"
                continue
            return chosen


def interactive_select(profiles: dict, initial: set[str] | None = None) -> list[str]:
    items = sorted_profile_items(profiles, initial)

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        # Non-TTY fallback: keep currently selected (or all if first run)
        return [pid for pid, _n, on, _f in items if on]

    def _wrap(stdscr):
        return interactive_select_curses(stdscr, items)

    try:
        result = curses.wrapper(_wrap)
    except curses.error:
        result = None

    if result is None:
        print("Cancelled.", file=sys.stderr)
        raise SystemExit(130)
    return result


def filter_preset(data: dict, selected: set[str]) -> dict:
    out = json.loads(json.dumps(data))  # deep copy
    for _dev_id, device in out.items():
        if not isinstance(device, dict):
            continue
        profiles = device.get("profiles") or {}
        if not isinstance(profiles, dict):
            continue
        # Keep selected profiles in frequency order
        ordered = sorted(
            ((k, v) for k, v in profiles.items() if k in selected),
            key=lambda kv: profile_freq_hz(kv[1] if isinstance(kv[1], dict) else {}),
        )
        device["profiles"] = {k: v for k, v in ordered}

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
        "--initial-selected",
        help="Previous SELECTED_PROFILES.txt or sdrs.selected.json — pre-check only those",
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

    initial: set[str] | None = None
    if args.initial_selected:
        initial = load_previous_selection(Path(args.initial_selected))

    if args.only:
        selected = [s.strip() for s in args.only.split(",") if s.strip()]
        missing = [s for s in selected if s not in profiles]
        if missing:
            print(f"error: unknown profile ids: {', '.join(missing)}", file=sys.stderr)
            return 1
    elif args.noninteractive:
        # Honor previous selection when present; otherwise keep all
        if initial is not None:
            selected = [pid for pid in profiles if pid in initial] or list(profiles.keys())
        else:
            selected = list(profiles.keys())
    else:
        selected = interactive_select(profiles, initial)

    selected_set = set(selected)
    filtered = filter_preset(data, selected_set)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(filtered, indent=2) + "\n", encoding="utf-8")

    if args.selected_file:
        Path(args.selected_file).write_text("\n".join(selected) + "\n", encoding="utf-8")

    names = []
    for pid in selected:
        names.append(str((profiles.get(pid) or {}).get("name") or pid))
    print(f"Kept {len(selected)} profile(s): " + ", ".join(names))
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        # Quiet halt: no traceback
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130) from None
