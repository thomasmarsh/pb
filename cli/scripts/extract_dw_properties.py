"""Extract DataWindow object property definitions from doc/pb2025r2 HTML docs.

DW object properties (BackColor, Alignment, Band, Border, etc.) describe the
attributes of controls within a DataWindow object. Each property has a name,
data type, valid values, and which controls it applies to.

Outputs JSON to lib/src/pb/lib/data/dw_properties.json containing:
  {
    "properties": {
      "alignment": {
        "name": "Alignment",
        "description": "The alignment of the control's text within its borders.",
        "applies_to": "Column, Computed Field, and Text controls",
        "data_type": "alignmentvalue",
        "values": {"0": "Left", "1": "Right", "2": "Center", "3": "Justified"},
        "syntax": {...},
        "usage": "..."
      }
    }
  }

Usage:
    cd cli && python3 scripts/extract_dw_properties.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup, Tag

ROOT = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2"
DW_REF = ROOT / "datawindow_reference"


def _clean(text: str) -> str:
    """Collapse whitespace in extracted text."""
    return re.sub(r"\s+", " ", text).strip()


def _extract_dw_property(html_path: Path) -> dict | None:
    """Extract a single DW object property from its HTML page."""
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
        "description": "",
        "applies_to": "",
        "data_type": "",
        "values": {},
        "syntax_pb": "",
        "syntax_describe": "",
        "usage": "",
    }

    # Get title
    h3 = content.find("h3")
    if h3:
        result["name"] = _clean(h3.get_text())

    if not result["name"]:
        return None

    # State machine
    state = "start"

    for tag in content.find_all(["p", "pre", "h3", "h4", "div"]):
        if not isinstance(tag, Tag):
            continue

        tag_text = _clean(tag.get_text())
        if not tag_text:
            continue

        if tag.name in ("p", "strong", "h3", "h4"):
            low = tag_text.lower()
            if low == "description":
                state = "description"
                continue
            elif low in ("applies to", "applies to"):
                state = "applies_to"
                continue
            elif low == "syntax":
                state = "syntax"
                continue
            elif low in ("parameter", "parameters", "argument", "arguments"):
                state = "parameter"
                continue
            elif low in ("values", "enumerated values"):
                state = "values"
                continue
            elif low in ("usage", "see also"):
                state = "done"
                continue

        if state == "description" and tag.name == "p":
            if not result["description"]:
                result["description"] = tag_text
            else:
                result["description"] += " " + tag_text

        elif state == "applies_to" and tag.name == "p":
            if not result["applies_to"]:
                result["applies_to"] = tag_text
            else:
                result["applies_to"] += " " + tag_text

        elif state == "syntax" and tag.name == "pre":
            text = tag_text
            if "dw_control" in text or "Object." in text:
                result["syntax_pb"] = text
            elif "Describe" in text or "Modify" in text:
                result["syntax_describe"] = text
            elif not result["syntax_pb"]:
                result["syntax_pb"] = text

        elif state == "values" and tag.name == "p":
            # Parse "N -- Description" pattern
            m = re.match(r"(\d+)\s*--?\s*(.*)", tag_text)
            if m:
                result["values"][m.group(1)] = m.group(2)

    # Also extract values from parameter tables
    for table in content.find_all("table"):
        header = table.find("tr")
        if header:
            ht = _clean(header.get_text()).lower()
            if "parameter" in ht or "argument" in ht:
                for row in table.find_all("tr")[1:]:
                    cells = row.find_all("td")
                    if len(cells) >= 2:
                        pname = _clean(cells[0].get_text())
                        pdesc = _clean(cells[1].get_text())
                        if pname:
                            # Check for data type info
                            if "long" in pdesc.lower() or "string" in pdesc.lower():
                                if not result["data_type"]:
                                    result["data_type"] = pname

    # Extract values from the full text — they appear as "0 -- (Default) Left"
    # or "0 -- Left" patterns, often inside parameter description cells
    full_text = content.get_text()
    for m in re.finditer(r"(\d+)\s*--\s*(.*?)(?:\n|,|$)", full_text):
        code = m.group(1).strip()
        desc = re.sub(r"\s+", " ", m.group(2)).strip()
        if code.isdigit() and desc and len(desc) < 80:
            result["values"][code] = desc

    return result if result["name"] else None


def _find_dw_property_files() -> list[Path]:
    """Find all DW object property HTML files."""
    if not DW_REF.exists():
        print(f"Warning: {DW_REF} not found", file=sys.stderr)
        return []

    # Get property list from the alphabetical list page
    list_page = DW_REF / "XREF_36021_Alphabetical_list.html"
    if list_page.exists():
        soup = BeautifulSoup(list_page.read_text(), "html.parser")
        content = soup.find("div", id="content")
        if content:
            links = []
            seen = set()
            for a in content.find_all("a"):
                href = a.get("href", "") or ""
                if not isinstance(href, str):
                    continue
                if (href.endswith(".html")
                        and href != "XREF_36021_Alphabetical_list.html"
                        and href not in seen):
                    seen.add(href)
                    fp = DW_REF / href
                    if fp.exists() and fp not in links:
                        links.append(fp)
            if links:
                return links

    # Fallback: all XREF_ HTML files
    return sorted(DW_REF.glob("XREF_*.html"))


def main() -> None:
    prop_files = _find_dw_property_files()
    print(f"Found {len(prop_files)} DW property pages", file=sys.stderr)

    properties: dict[str, dict] = {}
    errors = 0

    for fp in sorted(prop_files):
        result = _extract_dw_property(fp)
        if result:
            key = result["name"].lower()
            properties[key] = result
        else:
            errors += 1

    print(f"Extracted {len(properties)} DW properties ({errors} skipped)",
          file=sys.stderr)

    out_dir = Path(__file__).resolve().parent.parent / "lib" / "src" / "pb" / "lib" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "dw_properties.json"
    out_path.write_text(json.dumps({"properties": properties}, indent=2) + "\n")
    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
