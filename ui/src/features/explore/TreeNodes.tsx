// TreeNodes.tsx — Library/Object/Proc/DW tree node components.

import { Show, For, createMemo } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { TreeNode } from "./TreeNode.js";
import { procBadge } from "../../utils/format.js";
import { Package } from "../../utils/icons.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure } from "../../types/api.js";

export function libId(name: string): string { return `lib:${name}`; }
export function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
export function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }

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
          <For each={visibleProcs()}>
            {(proc) => <ProcNode objName={props.obj.name} proc={proc} depth={props.depth + 1} />}
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
