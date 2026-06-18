// TreeNodes.tsx — Library/Object/Proc/DW tree node components.

import { Show, For, createMemo } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { TreeNode } from "./TreeNode.js";
import { procBadge } from "../../utils/format.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure } from "../../types/api.js";

export function libId(name: string): string { return `lib:${name}`; }
export function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
export function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }
export function kindGroupId(objName: string, kind: "functions" | "events" | "subroutines"): string {
  return `kg:${objName}:${kind}`;
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

const KIND_BADGES: Record<string, string> = {
  powerscript: "badge-ps", datawindow: "badge-dw", project: "badge-proj",
};

function kindBadge(kind: string): string { return KIND_BADGES[kind] ?? "badge-proj"; }

function procKindGroup(procType: string): "functions" | "events" | "subroutines" {
  if (procType === "function") return "functions";
  if (procType === "subroutine") return "subroutines";
  return "events";
}

// ── Procedure Tree Node ───────────────────────────────────────────────────────

export function ProcNode(props: { objName: string; proc: ExploreProcedure; depth: number }) {
  const store = useExploreStore();
  const snap = store.getState();
  const nodeId = () => procId(props.objName, props.proc.name);
  const isSelected = () => snap().explore.selectedProc === nodeId();

  const summary = createMemo(() => {
    const p = props.proc;
    const parts: string[] = [];
    if (p.params) parts.push(truncate(p.params, 50));
    if (p.return_type) parts.push(`: ${p.return_type}`);
    if (p.cyclomatic != null) parts.push(`cc=${p.cyclomatic}`);
    return parts.join(" ");
  });

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      badge={{ text: props.proc.proc_type, cls: procBadge(props.proc.proc_type) }}
      name={props.proc.name}
      summary={summary()}
      selected={isSelected()}
      onClick={() => {
        store.dispatch({ tag: "explore", action: { type: "proc-select", objectName: props.objName, procName: props.proc.name, nodeId: nodeId() } });
        store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: props.objName, procName: props.proc.name } });
      }}
    />
  );
}

// ── Proc Group Node (Functions / Events / Subroutines) ────────────────────────

function ProcGroupNode(props: {
  nodeId: string;
  label: string;
  procs: ExploreProcedure[];
  objName: string;
  depth: number;
}) {
  return (
    <Show when={props.procs.length > 0}>
      <TreeNode nodeId={props.nodeId} depth={props.depth} name={props.label}>
        <For each={props.procs}>
          {(proc) => <ProcNode objName={props.objName} proc={proc} depth={props.depth + 1} />}
        </For>
      </TreeNode>
    </Show>
  );
}

// ── Object Tree Node ──────────────────────────────────────────────────────────

export function ObjectNode(props: { lib: string; obj: ExploreObject; depth: number }) {
  const store = useExploreStore();
  const snap = store.getState();
  const nodeId = () => objId(props.lib, props.obj.name);
  const isDw = () => props.obj.kind === "datawindow";

  const treeFilter = () => snap().explore.treeFilter.toLowerCase();

  const visibleProcs = createMemo(() => {
    const q = treeFilter();
    if (!q) return props.obj.procedures;
    return props.obj.procedures.filter(p => p.name.toLowerCase().includes(q));
  });

  const isVisible = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    if (props.obj.name.toLowerCase().includes(q)) return true;
    if (isDw()) return false;
    return visibleProcs().length > 0;
  });

  const grouped = createMemo(() => {
    const procs = visibleProcs();
    return {
      functions:   procs.filter(p => procKindGroup(p.proc_type) === "functions"),
      events:      procs.filter(p => procKindGroup(p.proc_type) === "events"),
      subroutines: procs.filter(p => procKindGroup(p.proc_type) === "subroutines"),
    };
  });

  return (
    <Show when={isVisible()}>
      <TreeNode
        nodeId={nodeId()}
        depth={props.depth}
        badge={{ text: props.obj.kind, cls: kindBadge(props.obj.kind) }}
        name={props.obj.name}
        onClick={isDw() ? () => store.dispatch({ tag: "explore", action: { type: "dw-select", dwName: props.obj.name, nodeId: nodeId() } }) : undefined}
      >
        <Show when={!isDw()}>
          <ProcGroupNode
            nodeId={kindGroupId(props.obj.name, "functions")}
            label={`Functions (${grouped().functions.length})`}
            procs={grouped().functions}
            objName={props.obj.name}
            depth={props.depth + 1}
          />
          <ProcGroupNode
            nodeId={kindGroupId(props.obj.name, "events")}
            label={`Events (${grouped().events.length})`}
            procs={grouped().events}
            objName={props.obj.name}
            depth={props.depth + 1}
          />
          <ProcGroupNode
            nodeId={kindGroupId(props.obj.name, "subroutines")}
            label={`Subroutines (${grouped().subroutines.length})`}
            procs={grouped().subroutines}
            objName={props.obj.name}
            depth={props.depth + 1}
          />
        </Show>
      </TreeNode>
    </Show>
  );
}

// ── Library Tree Node ─────────────────────────────────────────────────────────

export function LibraryNode(props: { lib: ExploreLibrary; depth: number }) {
  const store = useExploreStore();
  const snap = store.getState();
  const nodeId = () => libId(props.lib.name);

  const treeFilter = () => snap().explore.treeFilter.toLowerCase();

  const hasVisibleObjects = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    return props.lib.objects.some(obj => {
      if (obj.name.toLowerCase().includes(q)) return true;
      if (obj.kind === "datawindow") return false;
      return obj.procedures.some(p => p.name.toLowerCase().includes(q));
    });
  });

  return (
    <Show when={hasVisibleObjects()}>
      <TreeNode
        nodeId={nodeId()}
        depth={props.depth}
        icon={"▣"}
        name={props.lib.name}
        summary={`${props.lib.objects.length} objects`}
      >
        <For each={props.lib.objects}>
          {(obj) => <ObjectNode lib={props.lib.name} obj={obj} depth={props.depth + 1} />}
        </For>
      </TreeNode>
    </Show>
  );
}
