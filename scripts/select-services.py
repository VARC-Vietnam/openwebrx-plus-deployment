#!/usr/bin/env python3
"""Interactive checkbox UI to pick background decoding services."""
from __future__ import annotations

import argparse
import curses
import json
import sys
from pathlib import Path


def load_catalog(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not data:
        raise SystemExit("error: services catalog must be a non-empty list")
    out = []
    for row in data:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        out.append(
            {
                "id": str(row["id"]),
                "name": str(row.get("name") or row["id"]),
                "default": bool(row.get("default", False)),
            }
        )
    if not out:
        raise SystemExit("error: services catalog has no valid entries")
    return out


def load_previous(path: Path) -> set[str] | None:
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return None
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        if isinstance(data, dict) and isinstance(data.get("services_decoders"), list):
            return {str(x) for x in data["services_decoders"]}
        if isinstance(data, list):
            return {str(x) for x in data}
        return None
    ids = {
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith("#")
    }
    return ids or None


def build_items(catalog: list[dict], initial: set[str] | None) -> list[list]:
    """[id, name, selected]."""
    items = []
    for row in catalog:
        if initial is None:
            on = bool(row["default"])
        else:
            on = row["id"] in initial
        items.append([row["id"], row["name"], on])
    return items


def interactive_select_curses(stdscr, items: list[list], title: str) -> list[str] | None:
    curses.curs_set(0)
    stdscr.keypad(True)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_CYAN)
        curses.init_pair(2, curses.COLOR_WHITE, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_BLUE, -1)
        curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_BLUE)

    cursor = 0
    scroll = 0
    status = ""

    while True:
        stdscr.erase()
        height, width = stdscr.getmaxyx()
        header_lines = 8
        footer_lines = 3
        list_h = max(1, height - header_lines - footer_lines)

        if cursor < scroll:
            scroll = cursor
        elif cursor >= scroll + list_h:
            scroll = cursor - list_h + 1

        def put(y: int, x: int, text: str, attr=0) -> None:
            if y < 0 or y >= height:
                return
            stdscr.addnstr(y, x, text, max(0, width - x - 1), attr)

        put(0, 0, "=" * min(width - 1, 62), curses.color_pair(3) | curses.A_BOLD)
        put(1, 0, f"  {title}", curses.color_pair(3) | curses.A_BOLD)
        put(2, 0, "=" * min(width - 1, 62), curses.color_pair(3) | curses.A_BOLD)
        put(4, 0, "  ↑/↓ move   Space toggle   a all   n none")
        put(5, 0, "  Enter confirm (0 OK)   q cancel")
        put(6, 0, "  Tip: Sonde RS41 needs this + a schedule on the 403 MHz profile")

        for row in range(list_h):
            idx = scroll + row
            if idx >= len(items):
                break
            _sid, name, on = items[idx]
            mark = "x" if on else " "
            line = f"  [{mark}]  {name}"
            y = header_lines + row
            if idx == cursor and on:
                attr = curses.color_pair(1) | curses.A_BOLD
            elif idx == cursor:
                attr = curses.color_pair(5) | curses.A_BOLD
            elif on:
                attr = curses.color_pair(2) | curses.A_BOLD
            else:
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
        elif key in (ord("q"), 27):
            return None
        elif key in (curses.KEY_ENTER, 10, 13):
            return [sid for sid, _name, on in items if on]


def interactive_select(catalog: list[dict], initial: set[str] | None) -> list[str]:
    items = build_items(catalog, initial)
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return [sid for sid, _n, on in items if on]

    def _wrap(stdscr):
        return interactive_select_curses(
            stdscr, items, "Select background decoding services"
        )

    try:
        result = curses.wrapper(_wrap)
    except curses.error:
        result = None

    if result is None:
        print("Cancelled.", file=sys.stderr)
        raise SystemExit(130)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True, help="presets/services.json")
    ap.add_argument(
        "--output",
        required=True,
        help="Write background.json (services_enabled + services_decoders)",
    )
    ap.add_argument("--selected-file", help="Also write selected ids (one per line)")
    ap.add_argument(
        "--initial-selected",
        help="Previous SELECTED_SERVICES.txt or background.json",
    )
    ap.add_argument("--noninteractive", action="store_true")
    args = ap.parse_args()

    catalog = load_catalog(Path(args.catalog))
    initial: set[str] | None = None
    if args.initial_selected:
        initial = load_previous(Path(args.initial_selected))

    if args.noninteractive:
        if initial is not None:
            known = {r["id"] for r in catalog}
            selected = [r["id"] for r in catalog if r["id"] in initial and r["id"] in known]
            if not selected:
                selected = [r["id"] for r in catalog if r["default"]]
        else:
            selected = [r["id"] for r in catalog if r["default"]]
    else:
        selected = interactive_select(catalog, initial)

    payload = {
        "services_enabled": True,
        "services_decoders": selected,
    }
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if args.selected_file:
        Path(args.selected_file).write_text("\n".join(selected) + ("\n" if selected else ""), encoding="utf-8")

    names = {r["id"]: r["name"] for r in catalog}
    label = ", ".join(names.get(s, s) for s in selected) if selected else "(none)"
    print(f"Background decoders ({len(selected)}): {label}")
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130) from None
