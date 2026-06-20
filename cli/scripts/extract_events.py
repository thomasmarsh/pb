"""Extract PowerScript event definitions with PBM event IDs from doc/pb2025r2 HTML docs.

Events have Event IDs (like pbm_activate), arguments, and return values.
This data is not currently in pb_api.json.

Outputs JSON to pb_cli/data/ps_events.json containing:
  {
    "events": {
      "activate": {
        "name": "Activate",
        "event_id": "pbm_activate",
        "objects": "Window",
        "description": "Occurs just before the window becomes active.",
        "arguments": "None",
        "return_values": "Long.",
        "return_codes": {"0": "Continue processing"}
      }
    }
  }

Usage:
    cd cli && python3 scripts/extract_events.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup, Tag

ROOT = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2"
PS_REF = ROOT / "powerscript_reference"
OC_REF = ROOT / "objects_and_controls"


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _extract_event(html_path: Path) -> dict | None:
    """Extract event info from an HTML page."""
    try:
        html = html_path.read_text()
    except (OSError, UnicodeDecodeError):
        return None

    soup = BeautifulSoup(html, "html.parser")
    content = soup.find("div", id="content")
    if not content:
        return None

    result: dict = {
        "name": "",
        "event_ids": {},
        "description": "",
        "arguments": "",
        "return_values": "",
        "return_codes": {},
    }

    h3 = content.find("h3")
    if h3:
        result["name"] = _clean(h3.get_text())

    if not result["name"]:
        return None

    # Find Event ID tables — there can be multiple (one per object type)
    for table in content.find_all("table"):
        header = table.find("tr")
        if not header:
            continue
        ht = _clean(header.get_text()).lower()
        if "event id" in ht:
            for row in table.find_all("tr")[1:]:
                cells = row.find_all("td")
                if len(cells) >= 2:
                    event_id_text = _clean(cells[0].get_text())
                    obj_text = _clean(cells[1].get_text())
                    if event_id_text.startswith("pbm_"):
                        # Map object type to its event ID
                        obj_key = obj_text.lower() if obj_text else "default"
                        result["event_ids"][obj_key] = event_id_text
                    elif event_id_text.lower() == "none":
                        obj_key = obj_text.lower() if obj_text else "default"
                        result["event_ids"][obj_key] = "none"

    # Description
    state = "start"
    for tag in content.find_all(["p", "h3", "h4"]):
        if not isinstance(tag, Tag):
            continue
        tag_text = _clean(tag.get_text())
        if not tag_text:
            continue

        low = tag_text.lower()
        if low == "description":
            state = "description"
            continue
        elif low in ("event id", "arguments", "return values", "usage", "examples", "see also"):
            if low == "arguments":
                state = "arguments"
            elif low == "return values":
                state = "return_values"
            else:
                state = "done"
            continue

        if state == "description" and tag.name == "p":
            if not result["description"]:
                result["description"] = tag_text
            else:
                result["description"] += " " + tag_text

    # Return codes from text like "0 -- Continue processing"
    full_text = content.get_text()
    for m in re.finditer(r"(\d+)\s*--\s*(.*?)(?:\n|$)", full_text):
        code = m.group(1).strip()
        desc = m.group(2).strip()
        if code.isdigit() and desc:
            result["return_codes"][code] = desc

    return result if result["name"] else None


def _find_event_files() -> list[tuple[Path, str]]:
    """Find all event HTML files in powerscript_reference and objects_and_controls."""
    files: list[tuple[Path, str]] = []

    # PS reference events: *_event.html
    if PS_REF.exists():
        for fp in PS_REF.glob("*_event.html"):
            files.append((fp, "powerscript"))

    # OC reference events are embedded in class pages — we handle those separately
    return files


def main() -> None:
    event_files = _find_event_files()
    print(f"Found {len(event_files)} PS event pages", file=sys.stderr)

    events: dict[str, dict] = {}
    errors = 0

    for fp, source in sorted(event_files):
        result = _extract_event(fp)
        if result:
            key = result["name"].lower()
            if key not in events:
                events[key] = result
                events[key]["_source"] = source
            else:
                # Merge: prefer PS reference data
                if source == "powerscript":
                    events[key] = result
                    events[key]["_source"] = source
        else:
            errors += 1

    print(f"Extracted {len(events)} events ({errors} skipped)", file=sys.stderr)

    out_dir = Path(__file__).resolve().parent.parent / "pb_cli" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "ps_events.json"
    out_path.write_text(json.dumps({"events": events}, indent=2) + "\n")
    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
