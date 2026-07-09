// tests/features/DecompositionCandidatesCore.test.tsx — Unit tests for the
// pure forest-building helpers behind the evidence-paths detail pane.
// columnCoslice paths share long common prefixes (same seed column -> same
// intermediate statement, diverging only near the target); these functions
// group them into a forest (one tree per direction+seed) and compress
// shared prefixes so the UI doesn't repeat them on every row.

import { describe, it, expect } from "vitest";
import { buildPathForest, schemaObjectKey } from "../../app/src/views/features/analysis/DecompositionCandidatesCore.js";
import type { DecompositionEvidencePath, SchemaObjectRef } from "@pb/platform";

const col = (column: string): SchemaObjectRef => ({ kind: "column", namespace: null, table: "orders", column });
const sql = (proc: string, line: number): SchemaObjectRef => ({
  kind: "sql", file: "/tmp/x.srw", object: "n_svc", proc_name: proc, line,
});

describe("schemaObjectKey", () => {
  it("gives distinct keys to distinct columns", () => {
    expect(schemaObjectKey(col("a"))).not.toBe(schemaObjectKey(col("b")));
  });

  it("gives the same key to two refs describing the same object", () => {
    expect(schemaObjectKey(col("a"))).toBe(schemaObjectKey(col("a")));
  });
});

describe("buildPathForest", () => {
  it("collapses a shared first hop between two forward paths into one prefix row", () => {
    // seed=a -> stmt1 -> {b, c}: both paths share the "a -> stmt1" hop.
    const stmt1 = sql("proc1", 1);
    const paths: DecompositionEvidencePath[] = [
      { target: col("b"), direction: "forward", legs: [
        { from_object: col("a"), to_object: stmt1, leg_kind: "reads" },
        { from_object: stmt1, to_object: col("b"), leg_kind: "writes" },
      ] },
      { target: col("c"), direction: "forward", legs: [
        { from_object: col("a"), to_object: stmt1, leg_kind: "reads" },
        { from_object: stmt1, to_object: col("c"), leg_kind: "writes" },
      ] },
    ];

    const forest = buildPathForest(paths);
    expect(forest).toHaveLength(1);
    const tree = forest[0]!;
    expect(tree.direction).toBe("forward");
    expect(tree.pathCount).toBe(2);
    // root(a, depth0) + stmt1(depth1, shared) + b(depth2) + c(depth2) = 4 rows,
    // not 6 (which a naive flat render would produce).
    expect(tree.rows).toHaveLength(4);
    expect(tree.rows[0]).toMatchObject({ depth: 0, legKind: null, node: col("a") });
    expect(tree.rows[1]).toMatchObject({ depth: 1, legKind: "reads", node: stmt1 });
    expect(tree.rows[2]).toMatchObject({ depth: 2, legKind: "writes", isTarget: true });
    expect(tree.rows[3]).toMatchObject({ depth: 2, legKind: "writes", isTarget: true });
  });

  it("keeps two paths in separate trees when direction differs", () => {
    const stmt1 = sql("proc1", 1);
    const paths: DecompositionEvidencePath[] = [
      { target: stmt1, direction: "forward", legs: [{ from_object: col("a"), to_object: stmt1, leg_kind: "reads" }] },
      { target: stmt1, direction: "backward", legs: [{ from_object: stmt1, to_object: col("a"), leg_kind: "writes" }] },
    ];

    const forest = buildPathForest(paths);
    expect(forest).toHaveLength(2);
    expect(forest.map((t) => t.direction).sort()).toEqual(["backward", "forward"]);
    // Both trees are still rooted at the seed column "a", regardless of
    // which end of the raw leg chain "backward" happens to start from.
    for (const tree of forest) {
      expect(schemaObjectKey(tree.rootNode)).toBe(schemaObjectKey(col("a")));
      expect(tree.rows[0]!.depth).toBe(0);
      expect(schemaObjectKey(tree.rows[0]!.node)).toBe(schemaObjectKey(col("a")));
    }
  });

  it("keeps two paths in separate trees when the seed column differs", () => {
    const stmt1 = sql("proc1", 1);
    const paths: DecompositionEvidencePath[] = [
      { target: stmt1, direction: "forward", legs: [{ from_object: col("a"), to_object: stmt1, leg_kind: "reads" }] },
      { target: stmt1, direction: "forward", legs: [{ from_object: col("b"), to_object: stmt1, leg_kind: "reads" }] },
    ];

    const forest = buildPathForest(paths);
    expect(forest).toHaveLength(2);
    expect(forest.map((t) => schemaObjectKey(t.rootNode)).sort()).toEqual(
      [schemaObjectKey(col("a")), schemaObjectKey(col("b"))].sort(),
    );
  });

  it("renders a single path with no legs as an unbranched, self-target root row", () => {
    const paths: DecompositionEvidencePath[] = [
      { target: col("a"), direction: "forward", legs: [] },
    ];

    const forest = buildPathForest(paths);
    expect(forest).toHaveLength(1);
    expect(forest[0]!.rows).toEqual([{ depth: 0, legKind: null, node: col("a"), isTarget: true }]);
  });

  it("branches at the correct depth when paths share only a partial prefix", () => {
    // a -> stmt1 -> x -> b   and   a -> stmt1 -> y -> c
    // share depth 0-1 (a, stmt1) but diverge at depth 2 (x vs y).
    const stmt1 = sql("proc1", 1);
    const x = sql("proc_x", 2);
    const y = sql("proc_y", 3);
    const paths: DecompositionEvidencePath[] = [
      { target: col("b"), direction: "forward", legs: [
        { from_object: col("a"), to_object: stmt1, leg_kind: "reads" },
        { from_object: stmt1, to_object: x, leg_kind: "fk" },
        { from_object: x, to_object: col("b"), leg_kind: "writes" },
      ] },
      { target: col("c"), direction: "forward", legs: [
        { from_object: col("a"), to_object: stmt1, leg_kind: "reads" },
        { from_object: stmt1, to_object: y, leg_kind: "fk" },
        { from_object: y, to_object: col("c"), leg_kind: "writes" },
      ] },
    ];

    const forest = buildPathForest(paths);
    expect(forest).toHaveLength(1);
    const depths = forest[0]!.rows.map((r) => r.depth);
    // a(0), stmt1(1) shared once, then x(2)+b(3) and y(2)+c(3) each on their own branch.
    expect(depths).toEqual([0, 1, 2, 3, 2, 3]);
  });
});
