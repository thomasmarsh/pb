// TreeNodes.tsx — Library/Object/Proc/DW tree node components.

import { Show, For, createMemo } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { TreeNode } from "./TreeNode.js";
import { procBadge, Package, type ExploreLibrary, type ExploreObject, type ExploreProcedure } from "@pb/platform";

export function libId(name: string): string { return `lib:${name}`; }
export function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
export function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }
export function ctrlId(obj: string, owner: string): string { return `ctrl:${obj}:${owner}`; }

const KIND_BADGES: Record<string, string> = {
  powerscript: "badge-ps", datawindow: "badge-dw", project: "badge-proj",
};

function kindBadge(kind: string): string { return KIND_BADGES[kind] ?? "badge-proj"; }

// ── Procedure Tree Node ───────────────────────────────────────────────────────

export function ProcNode(props: { objName: string; proc: ExploreProcedure; depth: number }) {
  const store = useExploreStore();
  const snap = store.getState();
  const nodeId = () => procId(props.objName, props.proc.name);
  const isSelected = () => {
    const r = snap().nav.route;
    return r.view === "procedureDetail" && r.proc === props.proc.name && r.name === props.objName;
  };

  const summary = createMemo(() =>
    props.proc.cyclomatic != null ? `cc=${props.proc.cyclomatic}` : "",
  );

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      badge={{ text: props.proc.proc_type, cls: procBadge(props.proc.proc_type) }}
      name={props.proc.name}
      summary={summary()}
      selected={isSelected()}
      onClick={() => {
        store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: props.objName, procName: props.proc.name } });
      }}
    />
  );
}

// ── Control Group Tree Node ───────────────────────────────────────────────────

// Groups events owned by a control (ExploreProcedure.owner !== the object's own
// name) under a synthetic node, so control-level events nest under their
// owning control instead of sitting as flat peers of the object's own procs.
function ControlGroupNode(props: { objName: string; owner: string; procs: ExploreProcedure[]; depth: number }) {
  const nodeId = () => ctrlId(props.objName, props.owner);

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      name={props.owner}
      summary={`${props.procs.length} event${props.procs.length === 1 ? "" : "s"}`}
    >
      <For each={props.procs}>
        {(proc) => <ProcNode objName={props.objName} proc={proc} depth={props.depth + 1} />}
      </For>
    </TreeNode>
  );
}

// ── Object Tree Node ──────────────────────────────────────────────────────────

export function ObjectNode(props: { lib: string; obj: ExploreObject; depth: number }) {
  const store = useExploreStore();
  const snap = store.getState();
  const nodeId = () => objId(props.lib, props.obj.name);
  const isDw = () => props.obj.kind === "datawindow";
  const isSelected = () => {
    const r = snap().nav.route;
    return r.view === "objectDetail" && r.name === props.obj.name;
  };

  const treeFilter = () => snap().explore.treeFilter.toLowerCase();

  const visibleProcs = createMemo(() => {
    const q = treeFilter();
    if (!q) return props.obj.procedures;
    return props.obj.procedures.filter(p => p.name.toLowerCase().includes(q));
  });

  const ownProcs = createMemo(() =>
    visibleProcs().filter(p => !p.owner || p.owner === props.obj.name),
  );

  const controlGroups = createMemo(() => {
    const groups = new Map<string, ExploreProcedure[]>();
    for (const p of visibleProcs()) {
      if (p.owner && p.owner !== props.obj.name) {
        const arr = groups.get(p.owner) ?? [];
        arr.push(p);
        groups.set(p.owner, arr);
      }
    }
    return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));
  });

  const isVisible = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    if (props.obj.name.toLowerCase().includes(q)) return true;
    if (isDw()) return false;
    return visibleProcs().length > 0;
  });

  return (
    <Show when={isVisible()}>
      <TreeNode
        nodeId={nodeId()}
        depth={props.depth}
        badge={{ text: props.obj.kind, cls: kindBadge(props.obj.kind) }}
        name={props.obj.name}
        selected={isSelected()}
        onClick={isDw()
          ? () => store.dispatch({ tag: "explore", action: { tag: "dw-select", dwName: props.obj.name, nodeId: nodeId() } })
          : () => store.dispatch({ tag: "objects", action: { tag: "select", name: props.obj.name } })
        }
      >
        <Show when={!isDw()}>
          <For each={ownProcs()}>
            {(proc) => <ProcNode objName={props.obj.name} proc={proc} depth={props.depth + 1} />}
          </For>
          <For each={controlGroups()}>
            {([owner, procs]) => <ControlGroupNode objName={props.obj.name} owner={owner} procs={procs} depth={props.depth + 1} />}
          </For>
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
        icon={Package}
        name={props.lib.name}
        summary={`${props.lib.objects.length} objects`}
        onClick={() => store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "libraryDetail", name: props.lib.name } } })}
      >
        <For each={props.lib.objects}>
          {(obj) => <ObjectNode lib={props.lib.name} obj={obj} depth={props.depth + 1} />}
        </For>
      </TreeNode>
    </Show>
  );
}
