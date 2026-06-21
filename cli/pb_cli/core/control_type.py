"""Control type inference from PB naming conventions — no I/O dependencies."""

from __future__ import annotations

# Naming-convention map for window control type inference (Plan 90a).
# Prefix -> PB class name. Longer prefixes first to avoid false matches.
CONTROL_PREFIX_MAP: list[tuple[str, str]] = [
    ("ddplb_", "dropdownpicturelistbox"),
    ("ddlb_", "dropdownlistbox"),
    ("dddw_", "datawindowchild"),
    ("dw_", "datawindow"),
    ("cbx_", "checkbox"),
    ("hpb_", "hprogressbar"),
    ("htb_", "htrackbar"),
    ("hsb_", "hscrollbar"),
    ("vpb_", "vprogressbar"),
    ("vtb_", "vtrackbar"),
    ("vsb_", "vscrollbar"),
    ("plb_", "picturelistbox"),
    ("sh_", "statichyperlink"),
    ("ph_", "picturehyperlink"),
    ("rb_", "radiobutton"),
    ("cb_", "commandbutton"),
    ("st_", "statictext"),
    ("sle_", "singlelineedit"),
    ("mle_", "multilineedit"),
    ("em_", "editmask"),
    ("lb_", "listbox"),
    ("tv_", "treeview"),
    ("lv_", "listview"),
    ("rte_", "richtextedit"),
    ("tab_", "tab"),
    ("gr_", "graph"),
    ("ole_", "olecontrol"),
    ("uo_", "userobject"),
    ("gb_", "groupbox"),
    ("p_", "picture"),
    ("m_", "menu"),
]


def infer_control_type(control_name: str) -> str | None:
    """Infer PB control type from naming convention (e.g. dw_main -> datawindow)."""
    lower = control_name.lower()
    for prefix, pb_type in CONTROL_PREFIX_MAP:
        if lower.startswith(prefix):
            return pb_type
    return None
