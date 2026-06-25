"""Extract all PB functions and class methods from doc/pb2025r2 HTML docs.

Outputs a JSON file to lib/src/pb/lib/data/pb_api.json containing:
  - free_functions: sorted list of all free function names (lowercase)
  - class_methods: {class_name: [method_names]} (lowercase)

Usage:
    cd cli && python3 scripts/extract_pb_api.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2"
PS_REF = ROOT / "powerscript_reference"
OC_REF = ROOT / "objects_and_controls"

# Map HTML filename stem → PB class name (lowercase) for objects_and_controls.
CLASS_MAP: dict[str, str] = {
    "Window_control": "window", "WindowObject": "window",
    "DataWindow_control": "datawindow", "DataStore_object": "datastore",
    "DataWindowChild_object": "datawindowchild",
    "Menu_control": "menu", "Menu_object": "menu",
    "TreeView_control": "treeview", "ListView_control": "listview",
    "Tab_control": "tab", "TabControl_control": "tab",
    "EditMask_control": "editmask", "RichTextEdit_control": "richtextedit",
    "Graph_control": "graph", "ListBox_control": "listbox",
    "DropDownListBox_control": "dropdownlistbox",
    "PictureListBox_control": "picturelistbox",
    "DropDownPictureListBox_control": "dropdownpicturelistbox",
    "UserObject_control": "userobject", "UserObject_object": "userobject",
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
    "Animation_control": "animation", "OLE_control": "olecontrol",
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


def _extract_methods_from_html(html_path: Path) -> set[str]:
    """Extract method/function names from a PB docs HTML file."""
    try:
        html = html_path.read_text()
    except (OSError, UnicodeDecodeError):
        return set()
    soup = BeautifulSoup(html, "html.parser")
    names: set[str] = set()
    for table in soup.find_all("table"):
        header_row = table.find("tr")
        if not header_row:
            continue
        header_text = header_row.get_text().lower()
        if "function" not in header_text and "method" not in header_text:
            continue
        for row in table.find_all("tr")[1:]:
            cells = row.find_all("td")
            if cells:
                name = cells[0].get_text().strip()
                name = re.sub(r"\s*\(.*?\)\s*", "", name).strip()
                if name and name[0].isupper():
                    names.add(name.lower())
    return names


def extract_free_functions() -> set[str]:
    """Extract free function names from powerscript_reference.

    Extracts ALL *_func.html names, then removes any that appear in
    PB_CLASS_METHODS (those are class methods, not free functions).
    The powerscript reference doesn't distinguish free functions from
    class methods in its file naming, so we filter by class_methods.
    """
    funcs: set[str] = set()
    if not PS_REF.exists():
        print(f"Warning: {PS_REF} not found", file=sys.stderr)
        return funcs
    for html_file in PS_REF.glob("*_func.html"):
        name = html_file.stem.replace("_func", "")
        funcs.add(name.lower())
    return funcs


def extract_class_methods() -> dict[str, set[str]]:
    """Extract class methods from objects_and_controls."""
    class_methods: dict[str, set[str]] = {}
    if not OC_REF.exists():
        print(f"Warning: {OC_REF} not found", file=sys.stderr)
        return class_methods
    for html_file in OC_REF.glob("*.html"):
        class_name = CLASS_MAP.get(html_file.stem)
        if not class_name:
            continue
        methods = _extract_methods_from_html(html_file)
        if methods:
            class_methods.setdefault(class_name, set()).update(methods)
    return class_methods


def main() -> None:
    free_funcs = sorted(extract_free_functions())
    class_methods = extract_class_methods()

    # Remove class methods from free functions — they need a receiver
    all_class_method_names: set[str] = set()
    for methods in class_methods.values():
        all_class_method_names.update(methods)
    free_funcs = [f for f in free_funcs if f not in all_class_method_names]

    # Sort class method lists
    class_methods_sorted = {k: sorted(v) for k, v in sorted(class_methods.items())}

    total_methods = sum(len(v) for v in class_methods.values())
    print(f"Extracted {len(free_funcs)} free functions, "
          f"{len(class_methods_sorted)} classes, {total_methods} class methods")

    data = {
        "free_functions": free_funcs,
        "class_methods": class_methods_sorted,
    }

    out_dir = Path(__file__).resolve().parent.parent / "lib" / "src" / "pb" / "lib" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "pb_api.json"
    out_path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
