"""Extract full PB API signatures from doc/pb2025r2 HTML docs.

Outputs JSON to pb_cli/data/pb_api.json containing:
  - free_functions: {name: {signatures: [...]}}
  - free_function_names: sorted list of names (backward compat)
  - classes: {class_name: {methods: {name: {signatures: [...]}}, events: {...}}}
  - class_methods: {class_name: [method_names]} (backward compat)

Replaces the name-only extraction from extract_pb_api.py with full signatures.

Usage:
    cd cli && python3 scripts/extract_pb_api_sigs.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup, NavigableString, Tag

ROOT = Path(__file__).resolve().parent.parent.parent / "doc" / "pb2025r2"
PS_REF = ROOT / "powerscript_reference" / "docs.appeon.com" / "pb2025r2" / "powerscript_reference"
OC_REF = ROOT / "objects_and_controls" / "docs.appeon.com" / "pb2025r2" / "objects_and_controls"

# Map HTML filename stem -> PB class name (lowercase) for objects_and_controls.
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

# Type normalization patterns — order matters: longer/more specific first.
_TYPE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"PowerObject\b", re.I), "powerobject"),
    (re.compile(r"OLEStream\b", re.I), "olestream"),
    (re.compile(r"OLEStorage\b", re.I), "olestorage"),
    (re.compile(r"OLEControl\b", re.I), "olecontrol"),
    (re.compile(r"OLEObject\b", re.I), "oleobject"),
    (re.compile(r"TraceFile\b", re.I), "tracefile"),
    (re.compile(r"ProfileLine\b", re.I), "profileline"),
    (re.compile(r"ProfileClass\b", re.I), "profileclass"),
    (re.compile(r"ProfileRoutine\b", re.I), "profileroutine"),
    (re.compile(r"ErrorLog(ging)?\b", re.I), "errorlogging"),
    (re.compile(r"ErrorReturn\b", re.I), "errorreturn"),
    (re.compile(r"TransactionObject\b", re.I), "transaction"),
    (re.compile(r"DataWindowChild\b", re.I), "datawindowchild"),
    (re.compile(r"DataWindow(?!Child)\b", re.I), "datawindow"),
    (re.compile(r"DataStore\b", re.I), "datastore"),
    (re.compile(r"Environment\b", re.I), "environment"),
    (re.compile(r"MailSession\b", re.I), "mailsession"),
    (re.compile(r"MailMessage\b", re.I), "mailmessage"),
    (re.compile(r"TreeViewItem\b", re.I), "treeviewitem"),
    (re.compile(r"TreeView\b", re.I), "treeview"),
    (re.compile(r"ListViewItem\b", re.I), "listviewitem"),
    (re.compile(r"ListView\b", re.I), "listview"),
    (re.compile(r"GRDObject\b", re.I), "grdobject"),
    (re.compile(r"ContextInformation\b", re.I), "contextinformation"),
    (re.compile(r"ContextKeyword\b", re.I), "contextkeyword"),
    (re.compile(r"ClassDefinition\b", re.I), "classdefinition"),
    (re.compile(r"ScriptDefinition\b", re.I), "scriptdefinition"),
    (re.compile(r"VariableDefinition\b", re.I), "variabledefinition"),
    (re.compile(r"Font\b", re.I), "font"),
    (re.compile(r"PDFDoc(ument|Extractor)\b", re.I), "pdfdocextractor"),
    (re.compile(r"MenuItem\b", re.I), "menuitem"),
    # Simple types
    (re.compile(r"\blonglong\b", re.I), "longlong"),
    (re.compile(r"\blongptr\b", re.I), "longptr"),
    (re.compile(r"\bunsignedlong\b", re.I), "unsignedlong"),
    (re.compile(r"\bunsignedint(eger)?\b", re.I), "unsignedinteger"),
    (re.compile(r"\bunsigned\b", re.I), "unsigned"),
    (re.compile(r"\binteger\b", re.I), "integer"),
    (re.compile(r"\bboolean\b", re.I), "boolean"),
    (re.compile(r"\blong\b", re.I), "long"),
    (re.compile(r"\breal\b", re.I), "real"),
    (re.compile(r"\bdouble\b", re.I), "double"),
    (re.compile(r"\bdec(imal)?\b", re.I), "decimal"),
    (re.compile(r"\bint\b", re.I), "int"),
    (re.compile(r"\bbyte\b", re.I), "byte"),
    (re.compile(r"\bchar(acter)?\b", re.I), "char"),
    (re.compile(r"\bstring\b", re.I), "string"),
    (re.compile(r"\bblob\b", re.I), "blob"),
    (re.compile(r"\bdate\b", re.I), "date"),
    (re.compile(r"\btime\b", re.I), "time"),
    (re.compile(r"\bdatetime\b", re.I), "datetime"),
    (re.compile(r"\bany\b", re.I), "any"),
    (re.compile(r"\bnone\b", re.I), "void"),
    (re.compile(r"\bvoid\b", re.I), "void"),
]

# Return-value prose patterns: "Integer.", "String.", "Long.", etc.
_RETURN_TYPE_PREFIX_RE = re.compile(
    r"^(PowerObject|OLEStream|OLEStorage|OLEControl|OLEObject|"
    r"TraceFile|ErrorReturn|DataWindow|DataStore|TransactionObject|"
    r"Environment|ClassDefinition|PDFDocExtractor|MenuItem|"
    r"TreeViewItem|ListViewItem|ContextInformation|ContextKeyword|"
    r"MailSession|MailMessage|"
    r"unsignedlong|unsignedint(?:eger)?|unsigned|"
    r"longlong|longptr|integer|boolean|long|real|double|"
    r"dec(?:imal)?|int|byte|char(?:acter)?|string|blob|"
    r"date|time|datetime|any|none|void)\b\.?\s*",
    re.I,
)

# Pattern for "The datatype of X" (polymorphic return)
_POLYMORPHIC_RETURN_RE = re.compile(
    r"the\s+datatype\s+of\s+\w+", re.I,
)

# Pattern for "Returns 1 if..." / "Returns 0 if..."
_RETURNS_NUMBER_RE = re.compile(r"returns\s+(-?\d+)\s+if", re.I)


# ---------------------------------------------------------------------------
# Type normalization
# ---------------------------------------------------------------------------

def normalize_type(raw: str) -> str:
    """Normalize a raw PB type string to a canonical lowercase form."""
    s = raw.strip()
    if not s:
        return "any"
    # Direct prefix match (e.g. "Integer." or "String.")
    m = _RETURN_TYPE_PREFIX_RE.match(s)
    if m:
        return m.group(1).lower()
    # Try patterns from prose
    for pattern, canonical in _TYPE_PATTERNS:
        m = pattern.search(s)
        if m:
            return canonical
    return "any"


def extract_type_from_prose(prose: str) -> str:
    """Extract a PB type from a description like 'A long specifying...'."""
    return normalize_type(prose)


def parse_return_type(text: str) -> str:
    """Parse return type from a return-value paragraph.

    Handles patterns like:
      "Integer."
      "Returns 1 if it succeeds and -1 if an error occurs."
      "The datatype of n. Returns the absolute value..."
      "ErrorReturn. Returns one of the following values..."
      "Long. Returns 1 if it succeeds..."
    """
    text = text.strip()
    if not text:
        return "any"

    # Standalone type prefix: "Integer.", "String.", "Long.", "ErrorReturn."
    m = _RETURN_TYPE_PREFIX_RE.match(text)
    if m and (len(text) <= len(m.group(0)) + 2 or text[len(m.group(0))] == "R" or text[len(m.group(0))] == "r"):
        return m.group(1).lower()

    # "The datatype of X" -> polymorphic -> "any"
    if _POLYMORPHIC_RETURN_RE.search(text):
        return "any"

    # "ErrorReturn. Returns..."
    if text.startswith("ErrorReturn"):
        return "errorreturn"

    # Try any type word anywhere in the first sentence
    for pattern, canonical in _TYPE_PATTERNS:
        m = pattern.search(text[:200])
        if m:
            return canonical

    return "any"


# ---------------------------------------------------------------------------
# Syntax line parser (for powerscript_reference)
# ---------------------------------------------------------------------------

def parse_syntax_params(syntax_line: str, func_name: str) -> list[dict]:
    """Parse params from a PB syntax line.

    PB syntax uses `{, param}` for optional params and nested `{, param1 {, param2 }}`
    for multiple optional params. The braces are around the *comma*, not the param name.

    Examples:
        Open ( windowvar {, parent } )
        MessageBox ( title, text {, icon {, button {, default } } } )
    """
    # Match function_name ( ... )
    # The function name might have a receiver prefix: objectname.FuncName(...)
    pattern = re.compile(
        rf"(?:\w+\.)?{re.escape(func_name)}\s*\((.*?)\)",
        re.I | re.DOTALL,
    )
    m = pattern.search(syntax_line)
    if not m:
        return []
    inner = m.group(1).strip()
    if not inner:
        return []

    return _parse_pb_params(inner)


def _parse_pb_params(s: str) -> list[dict]:
    """Parse a PB parameter list string into a list of param dicts.

    Handles PB's optional-brace notation: `{, name}` means name is optional.
    Nested braces indicate multiple trailing optional params.
    """
    params: list[dict] = []
    i = 0
    n = len(s)
    optional_depth = 0  # > 0 means we're inside optional braces

    while i < n:
        ch = s[i]

        if ch == '{':
            # Count consecutive braces at this position
            brace_count = 0
            while i < n and s[i] == '{':
                brace_count += 1
                i += 1
            # Check if this starts with "{," (PB optional notation)
            j = i
            while j < n and s[j] in (' ', '\t', '\n', '\r'):
                j += 1
            if j < n and s[j] == ',':
                # This is PB optional-brace notation
                optional_depth += brace_count
                i = j + 1  # skip the comma
                continue
            else:
                # Not optional notation — skip these braces
                continue

        elif ch == '}':
            # Count consecutive close braces
            while i < n and s[i] == '}':
                optional_depth = max(0, optional_depth - 1)
                i += 1
            continue

        elif ch == ',':
            i += 1
            continue

        elif ch in (' ', '\t', '\n', '\r'):
            i += 1
            continue

        else:
            # This should be a parameter name
            # Read until comma, brace, or whitespace (but respect inner parens)
            name_chars: list[str] = []
            paren_depth = 0
            while i < n:
                c = s[i]
                if c == '(':
                    paren_depth += 1
                    name_chars.append(c)
                    i += 1
                elif c == ')':
                    paren_depth -= 1
                    name_chars.append(c)
                    i += 1
                elif c in (',', '{', '}') and paren_depth == 0:
                    break
                elif c in (' ', '\t', '\n', '\r') and paren_depth == 0:
                    break
                else:
                    name_chars.append(c)
                    i += 1

            name = ''.join(name_chars).strip()
            # Handle trailing parenthesized type hint like "n (optional)"
            m = re.match(r"(\w+)(?:\s*\(.*?\))?", name)
            if m:
                name = m.group(1).strip()

            if name:
                params.append({
                    "name": name.lower(),
                    "optional": optional_depth > 0,
                    "repeating": name.endswith("..."),
                })
                # Remove trailing ... from name
                if name.endswith("..."):
                    params[-1]["name"] = name[:-3].lower()

            continue

    return params


# ---------------------------------------------------------------------------
# Powerscript reference extraction
# ---------------------------------------------------------------------------

def extract_powerscript_functions() -> dict[str, dict]:
    """Extract free function signatures from powerscript_reference *_func.html files."""
    result: dict[str, dict] = {}
    if not PS_REF.exists():
        print(f"Warning: {PS_REF} not found", file=sys.stderr)
        return result

    for html_file in sorted(PS_REF.glob("*_func.html")):
        func_name = html_file.stem.replace("_func", "")
        try:
            html = html_file.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        soup = BeautifulSoup(html, "html.parser")

        sigs = _extract_func_signatures(soup, func_name)
        result[func_name.lower()] = {"signatures": sigs}

    return result


def _extract_func_signatures(soup: BeautifulSoup, func_name: str) -> list[dict]:
    """Extract all signature overloads for a function from its HTML soup."""
    # Strategy: check if there are Syntax N sections (h4 with "Syntax" in text).
    # Each lives inside a <div class="section">.
    # For single-syntax functions, there are no h4s — just <p>/ <strong> markers.

    syntax_sections: list[Tag] = []

    for div in soup.find_all("div", class_="section"):
        h4 = div.find("h4")
        if h4 and "yntax" in h4.get_text():
            syntax_sections.append(div)

    if syntax_sections:
        return [_extract_section_sig(sec, func_name) for sec in syntax_sections]
    else:
        sig = _extract_simple_sig(soup, func_name)
        return [sig] if sig else []


def _extract_section_sig(section: Tag, func_name: str) -> dict:
    """Extract one signature from a <div class='section'> containing an h4."""
    sig: dict = {"params": [], "return_type": "any"}

    # Walk all tags within this section
    state = "start"  # start -> description -> syntax -> argument -> return -> done
    param_names: list[str] = []
    last_param_name: str | None = None  # for two-row arg pattern

    for tag in section.find_all(recursive=True):
        if not isinstance(tag, Tag):
            continue
        tag_text = tag.get_text().strip()

        if tag_text in ("Return value", "Usage", "See also", "Examples"):
            if tag_text == "Return value":
                state = "return"
            else:
                state = "done"
            continue

        if tag.name in ("p", "strong") and tag_text == "Syntax":
            state = "syntax"
            continue

        if tag.name in ("p", "strong") and tag_text == "Argument":
            state = "argument"
            last_param_name = None
            continue

        if tag.name in ("p", "strong") and tag_text == "Description":
            if state == "start":
                state = "description"
            continue

        if tag.name in ("p", "strong") and tag_text == "Applies to":
            continue

        if state == "syntax" and tag.name == "pre":
            text = tag_text
            if func_name.lower() in text.lower() and "(" in text:
                params = parse_syntax_params(text, func_name)
                if params:
                    sig["params"] = params
                    param_names = [p["name"].lower() for p in params]

        if state == "argument" and tag.name == "p" and tag_text:
            # Two-row pattern: first <p> has param name, next <p> has description.
            # But "Description" may appear as a heading inside Argument.
            if tag_text == "Description":
                continue
            first_word = tag_text.split()[0].strip("({") if tag_text else ""

            if param_names and first_word.lower() in param_names:
                # This <p> is a param name — next <p> will be the description
                last_param_name = first_word.lower()
            elif last_param_name:
                # This <p> is the description for last_param_name
                ptype = extract_type_from_prose(tag_text)
                for p in sig["params"]:
                    if p["name"].lower() == last_param_name and "type" not in p:
                        p["type"] = ptype
                last_param_name = None

        if state == "return" and tag.name == "p" and tag_text:
            ret = parse_return_type(tag_text)
            if ret and ret != "any":
                sig["return_type"] = ret
                state = "done"

    return sig


def _extract_simple_sig(soup: BeautifulSoup, func_name: str) -> dict | None:
    """Extract a single-signature function (no Syntax N h4 headings)."""
    sig: dict = {"params": [], "return_type": "any"}

    body = soup.find("body")
    if not body:
        return None

    state = "start"
    param_names: list[str] = []
    last_param_name: str | None = None

    for tag in body.find_all(recursive=True):
        if not isinstance(tag, Tag):
            continue
        tag_text = tag.get_text().strip()

        if tag.name in ("strong", "p") and tag_text == "Syntax":
            state = "syntax"
            continue
        if tag.name in ("strong", "p") and tag_text == "Argument":
            state = "argument"
            last_param_name = None
            continue
        if tag.name in ("strong", "p") and tag_text == "Return value":
            state = "return"
            continue
        if tag.name in ("strong", "p") and tag_text in ("Usage", "Examples", "See also"):
            state = "done"
            continue
        if tag.name in ("strong", "p") and tag_text == "Description":
            if state == "start":
                state = "description"
            # "Description" also appears inside Argument section — skip
            continue

        if state == "syntax" and tag.name == "pre":
            text = tag_text
            # Skip example code (usually has assignment = or literal strings)
            if "=" in text and not text.lower().startswith(func_name.lower()):
                continue
            if re.search(r'\(\s*"', text) or re.search(r'\(\s*\d', text):
                continue
            if func_name.lower() in text.lower() and "(" in text:
                params = parse_syntax_params(text, func_name)
                if params:
                    sig["params"] = params
                    param_names = [p["name"].lower() for p in params]

        if state == "argument" and tag.name == "p" and tag_text:
            if tag_text == "Description":
                continue
            first_word = tag_text.split()[0].strip("({") if tag_text else ""
            if param_names and first_word.lower() in param_names:
                last_param_name = first_word.lower()
            elif last_param_name:
                ptype = extract_type_from_prose(tag_text)
                for p in sig["params"]:
                    if p["name"].lower() == last_param_name and "type" not in p:
                        p["type"] = ptype
                last_param_name = None

        if state == "return" and tag.name == "p":
            ret = parse_return_type(tag_text)
            if ret and ret != "any":
                sig["return_type"] = ret
                state = "done"

    return sig if sig["params"] or sig["return_type"] != "any" else None


# ---------------------------------------------------------------------------
# Objects & controls extraction
# ---------------------------------------------------------------------------

def extract_class_methods_and_events() -> dict[str, dict]:
    """Extract class method signatures and events from objects_and_controls HTML."""
    result: dict[str, dict] = {}
    if not OC_REF.exists():
        print(f"Warning: {OC_REF} not found", file=sys.stderr)
        return result

    for html_file in sorted(OC_REF.glob("*.html")):
        class_name = CLASS_MAP.get(html_file.stem)
        if not class_name:
            continue
        try:
            html = html_file.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        soup = BeautifulSoup(html, "html.parser")

        methods = _extract_oc_methods(soup)
        events = _extract_oc_events(soup)

        if methods or events:
            result[class_name] = {}
            if methods:
                result[class_name]["methods"] = methods
            if events:
                result[class_name]["events"] = events

    return result


def _extract_oc_methods(soup: BeautifulSoup) -> dict[str, dict]:
    """Extract method signatures from an objects_and_controls HTML page.

    The method table has columns: name, datatype returned, description.
    """
    methods: dict[str, dict] = {}
    for table in soup.find_all("table"):
        header_row = table.find("tr")
        if not header_row:
            continue
        header_text = header_row.get_text().lower()
        if "function" not in header_text and "method" not in header_text:
            continue

        for row in table.find_all("tr")[1:]:
            cells = row.find_all("td")
            if len(cells) < 2:
                continue
            raw_name = cells[0].get_text().strip()
            # Remove trailing parenthesized text like "methodname(arg)"
            name = re.sub(r"\s*\(.*?\)\s*", "", raw_name).strip()
            if not name or not name[0].isupper():
                continue
            name_lower = name.lower()

            return_type_raw = cells[1].get_text().strip()
            return_type = normalize_type(return_type_raw)

            if name_lower not in methods:
                methods[name_lower] = {"signatures": [{"params": [], "return_type": return_type}]}

    return methods


def _extract_oc_events(soup: BeautifulSoup) -> dict[str, dict]:
    """Extract event info from an objects_and_controls HTML page.

    Event tables have columns: name, description (no return type).
    """
    events: dict[str, dict] = {}
    for table in soup.find_all("table"):
        header_row = table.find("tr")
        if not header_row:
            continue
        header_text = header_row.get_text().lower()
        if "event" not in header_text:
            continue

        for row in table.find_all("tr")[1:]:
            cells = row.find_all("td")
            if not cells:
                continue
            raw_name = cells[0].get_text().strip()
            name = re.sub(r"\s*\(.*?\)\s*", "", raw_name).strip()
            if not name or not name[0].isupper():
                continue
            name_lower = name.lower()
            if name_lower not in events:
                events[name_lower] = {"signatures": [{"params": [], "return_type": "long"}]}

    return events


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    free_funcs_raw = extract_powerscript_functions()
    classes_raw = extract_class_methods_and_events()

    # Build backward-compatible name lists
    # Remove class methods from free functions
    all_class_method_names: set[str] = set()
    for cls_data in classes_raw.values():
        for mname in cls_data.get("methods", {}):
            all_class_method_names.add(mname)

    free_func_names = sorted(
        name for name in free_funcs_raw
        if name not in all_class_method_names
    )

    # Backward-compat class_methods dict
    class_methods_compat: dict[str, list[str]] = {}
    for cls_name, cls_data in sorted(classes_raw.items()):
        methods = cls_data.get("methods", {})
        if methods:
            class_methods_compat[cls_name] = sorted(methods.keys())

    total_free = len(free_func_names)
    total_classes = len(class_methods_compat)
    total_methods = sum(len(v) for v in class_methods_compat.values())
    sigs_count = sum(
        len(d.get("signatures", []))
        for d in free_funcs_raw.values()
    )
    sigs_nonempty = sum(
        1 for d in free_funcs_raw.values() if d.get("signatures")
    )
    print(f"Extracted {total_free} free functions "
          f"({sigs_nonempty} with signatures, {sigs_count} total overloads), "
          f"{total_classes} classes, {total_methods} class methods")

    data = {
        "free_functions": free_funcs_raw,
        "free_function_names": free_func_names,
        "classes": classes_raw,
        "class_methods": class_methods_compat,
    }

    out_dir = Path(__file__).resolve().parent.parent / "pb_cli" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "pb_api.json"
    out_path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
