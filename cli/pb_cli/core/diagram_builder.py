"""Pure diagram styling: color scales and graphviz attribute defaults — no I/O dependencies."""

KIND_COLORS = {
    'powerscript': '#5B8DD9',
    'datawindow':  '#56A85D',
    'project':     '#B0B0B0',
}
KIND_DEFAULT = '#D0D0D0'

_GRADIENT = [
    '#FFFFB2', '#FECC5C', '#FD8D3C',
    '#F03B20', '#BD0026', '#7A0177',
    '#49006A', '#2D004B', '#0D0221',
]

GRAPH_ATTRS = {
    'bgcolor':   '#1C1C1E',
    'fontname':  'Helvetica Neue,Helvetica,Arial,sans-serif',
    'fontcolor': '#E8E8E8',
    'pad':       '0.4',
}
NODE_DEFAULTS = {
    'fontname':  'Helvetica Neue,Helvetica,Arial,sans-serif',
    'fontsize':  '9',
    'fontcolor': '#1C1C1E',
    'penwidth':  '0',
}
EDGE_DEFAULTS = {
    'color':     '#606060',
    'arrowsize': '0.6',
    'penwidth':  '0.8',
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
    dot.attr('node', **ne)
    dot.attr('edge', **ee)
