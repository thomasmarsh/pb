"""Extract PB class methods from doc/pb2025r2 HTML docs.

Usage: python3 scripts/extract_class_methods.py

Outputs a Python dict literal to stdout. Paste into
lib/src/pb/lib/type_resolution.py as PB_CLASS_METHODS.
"""

from __future__ import annotations

import re
from pathlib import Path

from bs4 import BeautifulSoup

DOCS = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2" / "objects_and_controls"

# Map HTML filename stem → PB class name (lowercase)
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
    "UserObject_control": "userobject",
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


def extract() -> dict[str, set[str]]:
    class_methods: dict[str, set[str]] = {}
    for html_file in DOCS.glob("*.html"):
        class_name = CLASS_MAP.get(html_file.stem)
        if not class_name:
            continue
        with open(html_file) as f:
            soup = BeautifulSoup(f, "html.parser")
        for table in soup.find_all("table"):
            header_row = table.find("tr")
            if not header_row or "function" not in header_row.get_text().lower():
                continue
            for row in table.find_all("tr")[1:]:
                cells = row.find_all("td")
                if cells:
                    name = cells[0].get_text().strip()
                    name = re.sub(r"\s*\(.*?\)\s*", "", name).strip()
                    if name and name[0].isupper():
                        class_methods.setdefault(class_name, set()).add(name.lower())
    return class_methods


def main() -> None:
    class_methods = extract()
    total = sum(len(v) for v in class_methods.values())
    print(f"# Auto-extracted from doc/pb2025r2 HTML docs ({len(class_methods)} classes, {total} methods)")
    print("PB_CLASS_METHODS: dict[str, frozenset[str]] = {")
    for cls in sorted(class_methods):
        methods = sorted(class_methods[cls])
        items = ", ".join(f'"{m}"' for m in methods)
        print(f'    "{cls}": frozenset({{{items}}}),')
    print("}")


if __name__ == "__main__":
    main()
