"""Tests for intra-procedural data flow analysis (core/dataflow.py)."""

from pb_cli.core.cfg_builder import build_cfg
from pb_cli.core.dataflow import analyze_procedure, build_gen_kill

# --- AST construction helpers ------------------------------------------------


def _lvalue(name: str) -> dict:
    return {"segments": [{"name": name, "subscript": None}]}


def _exlvalue(name: str) -> dict:
    return {"tag": "ExLvalue", "contents": _lvalue(name)}


def _exint(val: str = "1") -> dict:
    return {"tag": "ExInt", "contents": val}


def _located(node: dict, line: int) -> dict:
    return {"line": line, "node": node}


def _assign(lhs: str, rhs: dict) -> dict:
    return {"tag": "BsAssign", "contents": [_lvalue(lhs), rhs]}


def _local_var(name: str, type_name: str = "integer") -> dict:
    return {
        "tag": "BsLocalVar",
        "mods": [],
        "type": {"tag": "PtPrimitive", "contents": type_name},
        "name": name,
        "init": None,
    }


def _for_loop(var: str, body: list) -> dict:
    return {
        "tag": "BsFor",
        "contents": {
            "var": _lvalue(var),
            "from": _exint("1"),
            "to": _exlvalue("n"),
            "step": None,
            "body": body,
        },
    }


def _if_stmt(cond: dict, then_body: list, else_body=None) -> dict:
    return {
        "tag": "BsIf",
        "contents": {
            "cond": cond,
            "then": then_body,
            "elseIfs": [],
            "else": else_body,
        },
    }


def _excall(fn: str, args: list) -> dict:
    return {"tag": "ExCall", "callee": _lvalue(fn), "args": args}


# --- Tests -------------------------------------------------------------------


class TestExtractDefsUses:
    def test_linear_defs_uses(self):
        """Linear body: BsLocalVar + BsAssign both produce def sites."""
        body = [
            _located(_local_var("x"), 1),
            _located(_assign("y", _exlvalue("x")), 2),
        ]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f.srf")
        all_def_vars = {d.var_name for bd in block_df.values() for d in bd.defs}
        all_use_vars = {u.var_name for bd in block_df.values() for u in bd.uses}
        assert "x" in all_def_vars
        assert "y" in all_def_vars
        assert "x" in all_use_vars

    def test_bsassign_nested_lhs_root_extracted(self):
        """Multi-segment lhs like obj.field: root var (obj) is the def."""
        nested_lhs = {
            "segments": [
                {"name": "obj", "subscript": None},
                {"name": "field", "subscript": None},
            ]
        }
        node = {"tag": "BsAssign", "contents": [nested_lhs, _exint("42")]}
        body = [_located(node, 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        all_def_vars = {d.var_name for bd in block_df.values() for d in bd.defs}
        assert "obj" in all_def_vars

    def test_bslocalvar_in_gen_set(self):
        """BsLocalVar puts the declared variable into the block's gen set."""
        body = [_located(_local_var("counter"), 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        entry_bd = block_df[cfg.entry]
        assert "counter" in entry_bd.gen
        assert any(d.kind == "local_var" for d in entry_bd.defs)

    def test_bsfor_loop_var_is_def(self):
        """BsFor loop variable is extracted as a definition site (kind='for_var')."""
        for_node = _for_loop("i", [])
        body = [_located(for_node, 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        all_def_vars = {d.var_name for bd in block_df.values() for d in bd.defs}
        assert "i" in all_def_vars, f"loop var 'i' not in defs; got {all_def_vars}"

    def test_bsfor_range_vars_are_uses(self):
        """BsFor from/to expressions produce use sites for the variables they reference."""
        for_node = _for_loop("i", [])
        body = [_located(for_node, 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        all_use_vars = {u.var_name for bd in block_df.values() for u in bd.uses}
        assert "n" in all_use_vars, f"'n' (used in 'to' expr) not in uses; got {all_use_vars}"

    def test_bsif_condition_is_use(self):
        """Variables in BsIf condition appear as use sites (kind='condition')."""
        if_node = _if_stmt(_exlvalue("flag"), [])
        body = [_located(if_node, 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        all_use_vars = {u.var_name for bd in block_df.values() for u in bd.uses}
        assert "flag" in all_use_vars

    def test_excall_args_idents_extracted(self):
        """Identifier strings in ExCall args are extracted as use sites."""
        call_node = {"tag": "BsCall", "contents": _excall("setnull", [["bar"]])}
        body = [_located(call_node, 1)]
        cfg = build_cfg(body)
        block_df = build_gen_kill(cfg, "obj", "proc", "f")
        all_use_vars = {u.var_name for bd in block_df.values() for u in bd.uses}
        assert "bar" in all_use_vars, f"arg ident 'bar' not in uses; got {all_use_vars}"


class TestReachingDefinitions:
    def test_def_propagates_through_branch(self):
        """Definition before an if-branch is visible in both branches and the merge."""
        body = [
            _located(_assign("y", _exint("1")), 1),
            _located(
                _if_stmt(
                    _exlvalue("flag"),
                    [_located(_assign("x", _exint("10")), 3)],
                ),
                2,
            ),
        ]
        pf = analyze_procedure(body, "obj", "proc", "f")
        all_reaching = set().union(*pf.reaching_out.values())
        assert "y" in all_reaching
        assert "x" in all_reaching

    def test_multiple_defs_same_var_all_recorded(self):
        """Two assignments to x in the same block both appear in all_defs."""
        body = [
            _located(_assign("x", _exint("1")), 1),
            _located(_assign("x", _exint("2")), 2),
        ]
        pf = analyze_procedure(body, "obj", "proc", "f")
        assert "x" in pf.all_defs
        assert len(pf.all_defs["x"]) == 2
        assert all(d.kind == "assign" for d in pf.all_defs["x"])
