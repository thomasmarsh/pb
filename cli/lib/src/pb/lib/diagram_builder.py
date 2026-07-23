"""Pure diagram styling: color scales, graphviz attribute defaults, and render functions — no I/O dependencies."""

from __future__ import annotations

import graphviz

KIND_COLORS = {
    "powerscript": "#5B8DD9",
    "datawindow": "#56A85D",
    "project": "#B0B0B0",
}
KIND_DEFAULT = "#D0D0D0"

_GRADIENT = [
    "#FFFFB2",
    "#FECC5C",
    "#FD8D3C",
    "#F03B20",
    "#BD0026",
    "#7A0177",
    "#49006A",
    "#2D004B",
    "#0D0221",
]

GRAPH_ATTRS = {
    "bgcolor": "#1C1C1E",
    "fontname": "Helvetica Neue,Helvetica,Arial,sans-serif",
    "fontcolor": "#E8E8E8",
    "pad": "0.4",
}
NODE_DEFAULTS = {
    "fontname": "Helvetica Neue,Helvetica,Arial,sans-serif",
    "fontsize": "9",
    "fontcolor": "#1C1C1E",
    "penwidth": "0",
}
EDGE_DEFAULTS = {
    "color": "#606060",
    "arrowsize": "0.6",
    "penwidth": "0.8",
}


def complexity_color(cc: int) -> str:
    idx = min(cc // 3, len(_GRADIENT) - 1)
    return _GRADIENT[idx]


def kind_color(kind: str) -> str:
    return KIND_COLORS.get(kind, KIND_DEFAULT)


def apply_defaults(dot, node_extra=None, edge_extra=None) -> None:
    dot.attr(**GRAPH_ATTRS)
    ne = {**NODE_DEFAULTS, **(node_extra or {})}
    ee = {**EDGE_DEFAULTS, **(edge_extra or {})}
    dot.attr("node", **ne)
    dot.attr("edge", **ee)


_OP_COLORS = {
    "SELECT": "#5B8DD9",
    "INSERT": "#56A85D",
    "UPDATE": "#fb923c",
    "DELETE": "#f87171",
    "retrieve": "#4ade80",
}
_DEFAULT_OP_COLOR = "#B0B0B0"


def render_inheritance(
    edges: list[tuple[str, str]],
    kind_map: dict[str, str],
    root: str | None,
) -> graphviz.Digraph:
    dot = graphviz.Digraph(engine="dot", name="inheritance")
    apply_defaults(dot)
    dot.attr(rankdir="TB", splines="ortho", nodesep="0.3", ranksep="0.6")
    dot.attr("edge", color="#8888AA", arrowsize="0.5", penwidth="0.7")

    seen: set[str] = set()
    for src, dst in edges:
        for name in (src, dst):
            if name not in seen:
                kind = kind_map.get(name, "")
                fill = kind_color(kind)
                shape = "box" if kind == "datawindow" else "ellipse"
                dot.node(
                    name,
                    shape=shape,
                    style="filled,rounded",
                    fillcolor=fill,
                    URL=f"pb://object/{name}#kind={kind}",
                )
                seen.add(name)
        dot.edge(src, dst)

    if root and root not in seen:
        kind = kind_map.get(root, "")
        dot.node(
            root,
            shape="doubleoctagon",
            style="filled",
            fillcolor="#FFD700",
            fontcolor="#1C1C1E",
            URL=f"pb://object/{root}#kind={kind}",
        )

    return dot


def render_calls(
    sub_nodes: set[str],
    sub_edges: list[tuple[str, str]],
    cc_map: dict[str, int],
    focal: str,
) -> graphviz.Digraph:
    dot = graphviz.Digraph(engine="fdp", name="calls")
    apply_defaults(dot)
    dot.attr(overlap="false", splines="curved", K="0.8")

    for name in sub_nodes:
        cc = cc_map.get(name) or 0
        is_focal = name == focal
        fill = "#FFD700" if is_focal else complexity_color(cc)
        shape = "doublecircle" if is_focal else "ellipse"
        width = "1.4" if is_focal else str(max(0.5, min(0.5 + cc / 8, 1.8)))
        label = f"{name}\\ncc={cc}" if cc > 3 else name
        dot.node(
            name,
            label=label,
            shape=shape,
            style="filled",
            fillcolor=fill,
            fontcolor="#1C1C1E",
            width=width,
            height=width,
            fixedsize="false",
            URL=f"pb://object/{name}#cc={cc}",
        )

    for u, v in sub_edges:
        if u == focal or v == focal:
            dot.edge(u, v, color="#FFD700AA", penwidth="1.2")
        else:
            dot.edge(u, v)

    return dot


def render_dw_tables(
    rows: list[tuple[str, str]],
    count_map: dict[str, int],
) -> graphviz.Digraph:
    dw_objects = sorted({r[0] for r in rows})
    tbl_names = sorted({r[1] for r in rows})

    dot = graphviz.Digraph(engine="dot", name="dw_tables")
    apply_defaults(dot, node_extra={"shape": "box"})
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.2", ranksep="1.2")

    with dot.subgraph(name="cluster_dw") as c:  # pyright: ignore[reportOptionalContextManager]
        c.attr(
            label="DataWindows",
            style="rounded",
            color="#5B8DD9",
            fontcolor="#E8E8E8",
            bgcolor="#2A2A3A",
        )
        for dw in dw_objects:
            nc = count_map.get(dw, 1)
            fill = complexity_color(nc - 1)
            c.node(
                f"dw_{dw}",
                label=dw,
                shape="box",
                style="filled,rounded",
                fillcolor=fill,
                fontsize="8",
                URL=f"pb://object/{dw}#tables={nc}",
            )

    with dot.subgraph(name="cluster_tables") as c:  # pyright: ignore[reportOptionalContextManager]
        c.attr(
            label="DB Tables",
            style="rounded",
            color="#56A85D",
            fontcolor="#E8E8E8",
            bgcolor="#1F2F1F",
        )
        for tbl in tbl_names:
            c.node(
                f"t_{tbl}",
                label=tbl,
                shape="cylinder",
                style="filled",
                fillcolor="#2E5E32",
                fontcolor="#C8F0CA",
                fontsize="8",
                URL=f"pb://table/{tbl}",
            )

    for dw, tbl in rows:
        dot.edge(f"dw_{dw}", f"t_{tbl}", color="#56A85D88", arrowsize="0.5", penwidth="0.7")

    return dot


def render_heatmap(
    rows: list[tuple[str, str, int, int]],
    inherit_edges: list[tuple[str, str]],
) -> graphviz.Graph:
    dot = graphviz.Graph(engine="sfdp", name="heatmap")
    apply_defaults(dot)
    dot.attr(
        # "prism" needs graphviz's triangulation library, which many distro
        # packages (Homebrew, several Linux distros) don't build in --
        # "scale" gives the same node-overlap removal via a core algorithm
        # present in every graphviz build.
        overlap="scale",
        splines="curved",
        outputorder="edgesfirst",
        K="1.2",
    )
    dot.attr("edge", style="invis")

    for name, kind, cc, fan_in in rows:
        fill = complexity_color(cc)
        size_f = round(max(0.3, min(fan_in / 15 + 0.35, 2.4)), 2)
        size = str(size_f)
        show_label = size_f >= 0.7 and (cc >= 5 or fan_in >= 10)
        label = name if show_label else ""
        fsize = "8" if show_label else "0"
        dot.node(
            name,
            label=label,
            shape="circle",
            style="filled",
            fillcolor=fill,
            fontcolor="#FFFFFFCC",
            width=size,
            height=size,
            fixedsize="true",
            fontsize=fsize,
            URL=f"pb://object/{name}#cc={cc},fan-in={fan_in}",
        )

    for src, dst in inherit_edges:
        dot.edge(src, dst)

    with dot.subgraph(name="cluster_legend") as lg:  # pyright: ignore[reportOptionalContextManager]
        lg.attr(
            label="Cyclomatic complexity",
            style="rounded",
            color="#555555",
            bgcolor="#2A2A2A",
            fontcolor="#E8E8E8",
            fontsize="9",
        )
        prev = "legend_anchor"
        lg.node(prev, style="invis", width="0", height="0", label="")
        for i, (lbl, fill) in enumerate(
            [
                ("0–2", _GRADIENT[0]),
                ("3–5", _GRADIENT[1]),
                ("6–8", _GRADIENT[2]),
                ("9+", _GRADIENT[4]),
            ]
        ):
            nid = f"legend_{i}"
            lg.node(
                nid,
                label=lbl,
                shape="circle",
                style="filled",
                fillcolor=fill,
                fontcolor="#1C1C1E",
                fontsize="7",
                width="0.5",
                height="0.5",
            )
            lg.edge(prev, nid, style="invis")
            prev = nid

    return dot


def render_sql_lineage(
    rows: list[tuple[str, str, str]],
) -> graphviz.Digraph:
    dot = graphviz.Digraph(engine="dot", name="sql_lineage")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.3", ranksep="1.2")
    dot.attr("node", shape="box", style="filled,rounded")

    seen_objects: set[str] = set()
    seen_tables: set[str] = set()

    for obj, tbl, op in rows:
        if obj not in seen_objects:
            dot.node(f"obj_{obj}", label=obj, fillcolor="#2A3050", fontcolor="#E8E8E8", fontsize="9", URL=f"pb://object/{obj}")
            seen_objects.add(obj)
        if tbl not in seen_tables:
            dot.node(f"tbl_{tbl}", label=tbl, shape="cylinder", fillcolor="#1F2F1F", fontcolor="#C8F0CA", fontsize="9", URL=f"pb://table/{tbl}")
            seen_tables.add(tbl)
        color = _OP_COLORS.get(op, _DEFAULT_OP_COLOR)
        dot.edge(f"obj_{obj}", f"tbl_{tbl}", color=color, xlabel=op, fontcolor=color, fontsize="7", penwidth="0.8")

    if not rows:
        dot.node("empty", label="No PowerScript SQL statements found", shape="plaintext", fontcolor="#5c5f72")

    return dot


def render_table_lineage(
    rows: list[tuple[str, str, str]],
    table_name: str,
) -> graphviz.Digraph:
    if not table_name:
        raise ValueError("table_name is required for table-lineage")

    dot = graphviz.Digraph(engine="dot", name="table_lineage")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.2", ranksep="1.4")
    dot.attr("node", shape="box", style="filled,rounded")

    dot.node(
        "__table__",
        label=table_name,
        shape="cylinder",
        style="filled",
        fillcolor="#2E5E32",
        fontcolor="#C8F0CA",
        fontsize="10",
        URL=f"pb://table/{table_name}",
    )

    seen_objects: set[str] = set()
    for obj, source, op in rows:
        node_id = f"obj_{obj}"
        if node_id not in seen_objects:
            is_dw = source == "datawindow"
            fill = "#2A3A4A" if is_dw else "#2A3050"
            badge = "dw" if is_dw else "ps"
            dot.node(node_id, label=f"{obj}\\n[{badge}]", fillcolor=fill, fontcolor="#E8E8E8", fontsize="8", URL=f"pb://object/{obj}")
            seen_objects.add(node_id)
        color = _OP_COLORS.get(op, _DEFAULT_OP_COLOR)
        dot.edge(node_id, "__table__", xlabel=op, color=color, fontcolor=color, fontsize="7", penwidth="0.8")

    if not rows:
        dot.node("empty", label=f"No references found for table: {table_name}", shape="plaintext", fontcolor="#5c5f72")

    return dot


def render_proc_tables(
    rows: list[dict[str, str | None]],
    table_name: str,
) -> graphviz.Digraph:
    dot = graphviz.Digraph(engine="dot", name="proc_tables")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.2", ranksep="1.4")
    dot.attr("node", shape="box", style="filled,rounded")

    seen_procs: set[str] = set()
    seen_tables: set[str] = set()

    for r in rows:
        proc_label = r["proc_name"] or r["object"]
        proc_id = f"proc_{r['object']}_{proc_label}"
        tbl_id = f"tbl_{r['table_name']}"
        node_label = f"{r['object']}\\n{proc_label}" if r["proc_name"] else r["object"]

        if proc_id not in seen_procs:
            is_dw = r["source"] == "datawindow"
            fill = "#2A3A4A" if is_dw else "#2A3050"
            dot.node(proc_id, label=node_label, fillcolor=fill, fontcolor="#E8E8E8", fontsize="8", URL=f"pb://object/{r['object']}")
            seen_procs.add(proc_id)
        if tbl_id not in seen_tables:
            dot.node(
                tbl_id, label=r["table_name"], shape="cylinder", fillcolor="#1F2F1F", fontcolor="#C8F0CA", fontsize="9",
                URL=f"pb://table/{r['table_name']}",
            )
            seen_tables.add(tbl_id)

        color = _OP_COLORS.get(r["operation"] or "", _DEFAULT_OP_COLOR)
        dot.edge(proc_id, tbl_id, color=color, xlabel=r["operation"], fontcolor=color, fontsize="7", penwidth="0.8")

    if not rows:
        msg = "No references found"
        if table_name:
            msg += f" for table: {table_name}"
        dot.node("empty", label=msg, shape="plaintext", fontcolor="#5c5f72")

    return dot


_FK_CATEGORY_STYLE = {
    "corroborated": ("#4ade80", "solid"),
    "unenforced": ("#f87171", "dashed"),
    "unused": ("#808080", "dotted"),
}


def render_fk_graph(
    edges: list[tuple[str, str, str, str, str]],
) -> graphviz.Digraph:
    """Plan 153 D2: implied-FK graph, code (`dw_join`) vs DDL evidence.

    Each edge is (from_table, from_column, to_table, to_column, category),
    category one of corroborated/unenforced/unused (see
    `pb.api.services.schema.get_fk_graph` for the classification). Dashed
    red edges (unenforced) are the actionable finding: a DW JOIN implies an
    FK relationship the DDL never declares.
    """
    dot = graphviz.Digraph(engine="dot", name="fk_graph")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.3", ranksep="1.0")
    dot.attr("node", shape="cylinder", style="filled,rounded")

    seen_tables: set[str] = set()
    for from_table, from_col, to_table, to_col, category in edges:
        for tbl in (from_table, to_table):
            if tbl not in seen_tables:
                dot.node(tbl, label=tbl, fillcolor="#1F2F1F", fontcolor="#C8F0CA", fontsize="9", URL=f"pb://table/{tbl}")
                seen_tables.add(tbl)
        color, style = _FK_CATEGORY_STYLE.get(category, ("#B0B0B0", "solid"))
        dot.edge(
            from_table, to_table,
            xlabel=f"{from_col}→{to_col}", color=color, style=style,
            fontcolor=color, fontsize="7", penwidth="0.8",
        )

    if not edges:
        dot.node("empty", label="No FK relationships found", shape="plaintext", fontcolor="#5c5f72")

    return dot


def render_lattice(
    concepts: list[dict[str, list[str]]],
    covers: list[dict[str, int]],
) -> graphviz.Digraph:
    """Plan 153 D7: window x table concept lattice, Hasse diagram.

    `concepts[i]` is `{"extent": [...windows], "intent": [...tables]}` and
    `covers` is `{"upper": i, "lower": j}` pairs -- the exact shapes
    `pb.pipeline.lattice.compute_window_table_lattice` returns (upper covers
    lower: lower's extent is a proper subset of upper's, with no concept
    strictly between). `rankdir="BT"` plus a lower->upper edge direction puts
    the top concept (largest extent, e.g. all windows) above the bottom
    (smallest extent), the conventional Hasse orientation.

    The visible label is deliberately just counts + a short table preview --
    a concept can have dozens of windows, so spelling them all out on the
    node would be unreadable at this scale. The full extent/intent go on the
    node's `tooltip` attribute instead: graphviz emits that as the node's
    SVG `<title>`, which the browser shows as a native hover tooltip with no
    frontend JS needed (found missing during Plan 153 D7's own manual
    browser verification -- a bare "5 windows" label with no way to see
    which 5 isn't informative enough to act on).
    """
    dot = graphviz.Digraph(engine="dot", name="lattice")
    apply_defaults(dot)
    dot.attr(rankdir="BT", nodesep="0.25", ranksep="0.6")
    dot.attr("node", shape="box", style="filled,rounded", fillcolor="#1F2A3F", fontcolor="#D6E4FF")

    _INTENT_PREVIEW = 3
    for i, concept in enumerate(concepts):
        extent, intent = concept["extent"], concept["intent"]
        preview = ", ".join(intent[:_INTENT_PREVIEW])
        if len(intent) > _INTENT_PREVIEW:
            preview += f", +{len(intent) - _INTENT_PREVIEW} more"
        label = f"{len(extent)} window{'s' if len(extent) != 1 else ''}\n{preview or '(no tables)'}"
        tooltip = (
            f"Windows ({len(extent)}): {', '.join(extent) or '(none)'}\n"
            f"Tables ({len(intent)}): {', '.join(intent) or '(none)'}"
        )
        dot.node(str(i), label=label, fontsize="8", tooltip=tooltip)

    for cov in covers:
        dot.edge(str(cov["lower"]), str(cov["upper"]))

    if not concepts:
        dot.node("empty", label="No window/table incidence found", shape="plaintext", fontcolor="#5c5f72")

    return dot
