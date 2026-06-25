// components/BreadcrumbBar.tsx — Typed-icon breadcrumb strip.

import { For, Show, createSignal } from "solid-js";
import { Dynamic } from "solid-js/web";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { type BreadcrumbSegment, type Route, type IconComp } from "@pb/platform";
import {
  LayoutDashboard,
  Box,
  Code2,
  Grid3X3,
  Database,
  MessageSquare,
  BarChart2,
  List,
  Package,
} from "@pb/platform";

// Icon key → Lucide component, resolved at render time (never stored in state).
const ICON_MAP: Record<string, IconComp> = {
  library:    LayoutDashboard,
  object:     Box,
  procedure:  Code2,
  datawindow: Grid3X3,
  table:      Database,
  ask:        MessageSquare,
  analysis:   BarChart2,
  list:       List,
  window:     Package,
};

function resolveIcon(key: string): IconComp {
  return ICON_MAP[key] ?? Box;
}

// ── Display item model ────────────────────────────────────────────────────────

type DisplayItem =
  | { kind: "crumb";    crumb: BreadcrumbSegment; isLast: boolean }
  | { kind: "ellipsis"; hidden: BreadcrumbSegment[] };

export function buildDisplay(crumbs: BreadcrumbSegment[]): DisplayItem[] {
  if (crumbs.length <= 5) {
    return crumbs.map((c, i) => ({
      kind: "crumb" as const,
      crumb: c,
      isLast: i === crumbs.length - 1,
    }));
  }
  const first2 = crumbs.slice(0, 2).map((c): DisplayItem => ({ kind: "crumb", crumb: c, isLast: false }));
  const hidden  = crumbs.slice(2, crumbs.length - 2);
  const last2   = crumbs.slice(-2).map((c, i): DisplayItem => ({ kind: "crumb", crumb: c, isLast: i === 1 }));
  return [...first2, { kind: "ellipsis" as const, hidden }, ...last2];
}

// ── Sub-components ────────────────────────────────────────────────────────────

function Sep(): JSX.Element {
  return <span class="bc-sep" aria-hidden="true">›</span>;
}

function BcIcon(props: { key: string }): JSX.Element {
  return <Dynamic component={resolveIcon(props.key)} size={13} />;
}

// ── BreadcrumbBar ─────────────────────────────────────────────────────────────

export function BreadcrumbBar(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();
  const crumbs = () => snap().nav.crumbs;

  function navigateTo(route: Route): void {
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route } });
  }

  function renderItem(item: DisplayItem, idx: number): JSX.Element {
    const isFirst = idx === 0;

    if (item.kind === "ellipsis") {
      return <EllipsisSegment hidden={item.hidden} navigate={navigateTo} showSep={!isFirst} />;
    }

    return (
      <>
        <Show when={!isFirst}><Sep /></Show>
        <Show
          when={!item.isLast}
          fallback={
            <span
              class="bc-segment bc-current"
              aria-current="page"
              aria-label={item.crumb.label}
            >
              <span class="bc-icon" aria-hidden="true"><BcIcon key={item.crumb.icon} /></span>
              <span class="bc-label">{item.crumb.label}</span>
            </span>
          }
        >
          <button
            class="bc-segment bc-link"
            onClick={() => navigateTo(item.crumb.route)}
            aria-label={`Navigate to ${item.crumb.label}`}
          >
            <span class="bc-icon" aria-hidden="true"><BcIcon key={item.crumb.icon} /></span>
            <span class="bc-label">{item.crumb.label}</span>
          </button>
        </Show>
      </>
    );
  }

  const items = () => buildDisplay(crumbs());

  return (
    <nav class="breadcrumb-bar" aria-label="Breadcrumb">
      <For each={items()}>
        {(item, i) => renderItem(item, i())}
      </For>
    </nav>
  );
}

// ── EllipsisSegment ───────────────────────────────────────────────────────────

function EllipsisSegment(props: {
  hidden: BreadcrumbSegment[];
  navigate: (r: Route) => void;
  showSep: boolean;
}): JSX.Element {
  const [open, setOpen] = createSignal(false);

  return (
    <>
      <Show when={props.showSep}><Sep /></Show>
      <div
        class="bc-ellipsis-wrap"
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
      >
        <button
          class="bc-segment bc-ellipsis"
          aria-label="Show hidden breadcrumb segments"
          aria-expanded={open()}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
        >
          …
        </button>
        <Show when={open()}>
          <div class="bc-dropdown" role="list">
            <For each={props.hidden}>
              {(seg) => (
                <button
                  role="listitem"
                  class="bc-dropdown-item"
                  onClick={() => { setOpen(false); props.navigate(seg.route); }}
                  aria-label={`Navigate to ${seg.label}`}
                >
                  <span class="bc-icon" aria-hidden="true"><BcIcon key={seg.icon} /></span>
                  <span class="bc-label">{seg.label}</span>
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>
      <Sep />
    </>
  );
}
