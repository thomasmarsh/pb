"""Extract PB class property definitions from objects_and_controls HTML docs.

Each class (Window, DataWindow, etc.) has properties with datatypes and
descriptions. This data is not currently in pb_api.json.

Outputs JSON to pb_cli/data/class_properties.json containing:
  {
    "classes": {
      "window": {
        "properties": {
          "accessibledescription": {
            "name": "AccessibleDescription",
            "datatype": "String",
            "description": "A description of the control..."
          }
        }
      }
    }
  }

Usage:
    cd cli && python3 scripts/extract_class_properties.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup, Tag

ROOT = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2"
OC_REF = ROOT / "objects_and_controls"

# Map HTML filename stem -> PB class name (same as other scripts)
CLASS_MAP: dict[str, str] = {
    "Window_control": "window", "WindowObject": "window",
    "DataWindow_control": "datawindow", "DataStore_object": "datastore",
    "DataWindowChild_object": "datawindowchild",
    "Menu_object": "menu",
    "TreeView_control": "treeview", "ListView_control": "listview",
    "Tab_control": "tab",
    "EditMask_control": "editmask", "RichTextEdit_control": "richtextedit",
    "Graph_object": "graph",
    "ListBox_control": "listbox",
    "DropDownListBox_control": "dropdownlistbox",
    "PictureListBox_control": "picturelistbox",
    "DropDownPictureListBox_control": "dropdownpicturelistbox",
    "UserObject_object": "userobject",
    "CommandButton_control": "commandbutton",
    "RadioButton_control": "radiobutton", "CheckBox_control": "checkbox",
    "StaticText_control": "statictext",
    "SingleLineEdit_control": "singlelineedit",
    "MultiLineEdit_control": "multilineedit",
    "Picture_control": "picture", "PictureButton_control": "picturebutton",
    "GroupBox_control": "groupbox", "Line_control": "line",
    "Oval_control": "oval", "Rectangle_control": "rectangle",
    "RoundRectangle_control": "roundrectangle",
    "HProgressBar_control": "hprogressbar",
    "VProgressBar_control": "vprogressbar",
    "HTrackBar_control": "htrackbar", "VTrackBar_control": "vtrackbar",
    "HScrollBar_control": "hscrollbar", "VScrollBar_control": "vscrollbar",
    "Animation_control": "animation", "OLEControl_control": "olecontrol",
    "DatePicker_control": "datepicker",
    "MonthCalendar_control": "monthcalendar",
    "InkEdit_control": "inkedit", "InkPicture_control": "inkpicture",
    "WebBrowser_control": "webbrowser",
    "StaticHyperLink_control": "statichyperlink",
    "PictureHyperLink_control": "picturehyperlink",
    "Application_object": "application",
    "Transaction_object": "transaction",
    "RibbonBar_control": "ribbonbar",
}


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _extract_class_properties(html_path: Path) -> dict[str, dict]:
    """Extract properties from an objects_and_controls HTML page."""
    try:
        html = html_path.read_text()
    except (OSError, UnicodeDecodeError):
        return {}

    soup = BeautifulSoup(html, "html.parser")
    content = soup.find("div", id="content")
    if not content:
        return {}

    properties: dict[str, dict] = {}

    # Find the properties table — it has columns: Property | Datatype | Description
    for table in content.find_all("table"):
        header_row = table.find("tr")
        if not header_row:
            continue
        header_text = _clean(header_row.get_text()).lower()
        if "property" in header_text and "datatype" in header_text:
            for row in table.find_all("tr")[1:]:
                cells = row.find_all("td")
                if len(cells) >= 3:
                    prop_name = _clean(cells[0].get_text())
                    prop_datatype = _clean(cells[1].get_text())
                    prop_desc = _clean(cells[2].get_text())
                    if prop_name:
                        key = prop_name.lower()
                        properties[key] = {
                            "name": prop_name,
                            "datatype": prop_datatype,
                            "description": prop_desc,
                        }
            break  # Only first matching table

    return properties


def main() -> None:
    if not OC_REF.exists():
        print(f"Warning: {OC_REF} not found", file=sys.stderr)
        return

    classes: dict[str, dict] = {}
    total_props = 0

    for html_file in sorted(OC_REF.glob("*.html")):
        class_name = CLASS_MAP.get(html_file.stem)
        if not class_name:
            continue
        props = _extract_class_properties(html_file)
        if props:
            if class_name not in classes:
                classes[class_name] = {"properties": {}}
            classes[class_name]["properties"].update(props)
            total_props += len(props)

    print(f"Extracted {len(classes)} classes, {total_props} properties",
          file=sys.stderr)

    out_dir = Path(__file__).resolve().parent.parent / "pb_cli" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "class_properties.json"
    out_path.write_text(json.dumps(classes, indent=2) + "\n")
    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
