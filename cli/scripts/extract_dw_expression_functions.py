"""Extract DataWindow expression function signatures from doc/pb2025r2 HTML docs.

DW expression functions (Abs, Avg, Count, If, etc.) are used in computed fields,
validation rules, and filter expressions within DataWindow objects. They are
distinct from PowerScript free functions.

Outputs JSON to pb_cli/data/dw_expression_functions.json containing:
  {
    "functions": {
      "abs": {
        "name": "Abs",
        "syntax": "Abs ( n )",
        "params": [{"name": "n", "description": "..."}],
        "return_type": "The datatype of n",
        "description": "Calculates the absolute value of a number.",
        "usage": "...",
        "applies_to": "..."
      }
    }
  }

Usage:
    cd cli && python3 scripts/extract_dw_expression_functions.py
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


def _extract_dw_function(html_path: Path) -> dict | None:
    """Extract a single DW expression function from its HTML page."""
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
        "syntax": "",
        "params": [],
        "return_type": "",
        "description": "",
        "usage": "",
        "examples": [],
        "applies_to": "",
    }

    # Get title from h3
    h3 = content.find("h3")
    if h3:
        result["name"] = _clean(h3.get_text())

    if not result["name"]:
        return None

    # State machine through sections
    state = "start"

    for tag in content.find_all(["p", "pre", "h3", "h4", "div"]):
        if not isinstance(tag, Tag):
            continue

        tag_text = _clean(tag.get_text())
        if not tag_text:
            continue

        # Detect section headers
        if tag.name in ("p", "strong", "h3", "h4"):
            low = tag_text.lower()
            if low == "description":
                state = "description"
                continue
            elif low == "syntax":
                state = "syntax"
                continue
            elif low in ("argument", "arguments"):
                state = "argument"
                continue
            elif low == "return value":
                state = "return"
                continue
            elif low in ("usage", "examples", "see also"):
                if state == "start":
                    state = "usage"
                elif low == "examples":
                    state = "examples"
                elif low == "see also":
                    state = "done"
                continue
            elif low == "applies to":
                state = "applies_to"
                continue
            elif tag.name in ("h3", "h4") and tag_text == result["name"]:
                continue

        if state == "description" and tag.name == "p":
            if not result["description"]:
                result["description"] = tag_text
            elif tag.name == "p":
                result["description"] += " " + tag_text

        elif state == "syntax" and tag.name == "pre":
            result["syntax"] = tag_text

        elif state == "argument":
            # Table with Argument/Description columns
            if tag.name == "div" and "table" in tag.get("class", []):
                table = tag.find("table")
                if table:
                    rows = table.find_all("tr")[1:]  # skip header
                    for row in rows:
                        cells = row.find_all("td")
                        if len(cells) >= 2:
                            param_name = _clean(cells[0].get_text())
                            param_desc = _clean(cells[1].get_text())
                            if param_name:
                                result["params"].append({
                                    "name": param_name,
                                    "description": param_desc,
                                })
            elif tag.name == "p" and result["params"]:
                # Sometimes params are in <p> tags: "param_name Description text"
                pass

        elif state == "return" and tag.name == "p":
            if not result["return_type"]:
                result["return_type"] = tag_text

        elif state == "usage" and tag.name == "p":
            result["usage"] += (" " if result["usage"] else "") + tag_text

        elif state == "examples" and tag.name == "pre":
            result["examples"].append(tag_text)

        elif state == "applies_to" and tag.name == "p":
            result["applies_to"] += (" " if result["applies_to"] else "") + tag_text

    # Also parse argument tables that appear after syntax
    if not result["params"]:
        for table in content.find_all("table"):
            header = table.find("tr")
            if header:
                ht = _clean(header.get_text()).lower()
                if "argument" in ht and "description" in ht:
                    for row in table.find_all("tr")[1:]:
                        cells = row.find_all("td")
                        if len(cells) >= 2:
                            param_name = _clean(cells[0].get_text())
                            param_desc = _clean(cells[1].get_text())
                            if param_name and param_name.lower() not in ("description",):
                                result["params"].append({
                                    "name": param_name,
                                    "description": param_desc,
                                })

    # Clean up
    result["usage"] = result["usage"].strip()
    result["applies_to"] = result["applies_to"].strip()

    return result if result["name"] else None


def _find_dw_function_files() -> list[Path]:
    """Find all DW expression function HTML files.

    We identify them by looking at the alphabetical list page and following
    links, or by iterating all HTML files that aren't property/XREF pages.
    """
    if not DW_REF.exists():
        print(f"Warning: {DW_REF} not found", file=sys.stderr)
        return []

    # Strategy: find the alphabetical list page and extract function links
    list_page = DW_REF / "XREF_36405_Alphabetical_list.html"
    if list_page.exists():
        soup = BeautifulSoup(list_page.read_text(), "html.parser")
        content = soup.find("div", id="content")
        if content:
            links = []
            seen = set()
            for a in content.find_all("a"):
                href = a.get("href", "")
                if (href.endswith(".html")
                        and href != "XREF_36405_Alphabetical_list.html"
                        and href not in seen):
                    seen.add(href)
                    name = _clean(a.get_text())
                    if name and name not in ("Prev", "Up", "Next", "Home", ""):
                        fp = DW_REF / href
                        if fp.exists():
                            links.append(fp)
            if links:
                return links

    # Fallback: iterate all non-XREF HTML files
    return sorted(f for f in DW_REF.glob("*.html") if not f.stem.startswith("XREF_"))


def main() -> None:
    func_files = _find_dw_function_files()
    print(f"Found {len(func_files)} DW expression function pages", file=sys.stderr)

    functions: dict[str, dict] = {}
    errors = 0

    for fp in sorted(func_files):
        result = _extract_dw_function(fp)
        if result:
            key = result["name"].lower()
            functions[key] = result
        else:
            errors += 1

    print(f"Extracted {len(functions)} DW expression functions ({errors} skipped)",
          file=sys.stderr)

    out_dir = Path(__file__).resolve().parent.parent / "pb_cli" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "dw_expression_functions.json"
    out_path.write_text(json.dumps({"functions": functions}, indent=2) + "\n")
    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
