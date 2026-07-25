// Diagnostics.tsx — Diagnostics: parse/ingestion error browser + pipeline timeline.

import { For, Show, createMemo, createResource, onMount, createSignal } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { DiagnosticsKindFilter, DiagnosticsTimelineStep } from "@pb/platform";
import { PAGE_SIZE } from "@pb/platform";
import { anonymizeText, highlightAsync, type ParseErrorRow } from "@pb/platform";
import { CodeBlock, CopyButton } from "@pb/platform";

const KIND_FILTERS: { value: DiagnosticsKindFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "powerscript", label: "PowerScript / Lex" },
  { value: "sql", label: "SQL" },
];

function TypeCoverageCard(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const tc = () => snap().diagnostics.typeCoverage;

  return (
    <Show when={tc()}>
      <div class="card" style={{ "margin-bottom": "16px" }}>
        <div class="card-header"><h2>Type Coverage</h2></div>
        <div class="metric-grid">
          <div class="metric-card">
            <div class="label">Token Coverage</div>
            <div class="value">{tc()!.token_coverage_pct}%</div>
          </div>
          <div class="metric-card">
            <div class="label">Var Refs Resolved</div>
            <div class="value">{tc()!.var_ref_pct}%</div>
          </div>
          <div class="metric-card">
            <div class="label">Calls Resolved</div>
            <div class="value">{tc()!.call_pct}%</div>
          </div>
        </div>
        <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "12px" }}>
          {tc()!.resolved_identifier_tokens.toLocaleString()} / {tc()!.total_identifier_tokens.toLocaleString()} identifier
          tokens matched a resolved var-ref or call row (token-level denominator — an identifier that never parsed
          into either table counts against this even when the parsed rows above resolve almost perfectly)
        </div>
        <div style={{ display: "flex", gap: "16px", "flex-wrap": "wrap" }}>
          <table class="data-table" style={{ flex: "1", "min-width": "220px" }}>
            <thead>
              <tr><th colspan="3">Var Ref Kinds</th></tr>
              <tr><th>Kind</th><th>Confidence</th><th>Count</th></tr>
            </thead>
            <tbody>
              <For each={tc()!.var_ref_kind_confidence_counts}>
                {(row) => <tr><td class="name-cell">{row.kind}</td><td>{row.confidence}</td><td>{row.count}</td></tr>}
              </For>
            </tbody>
          </table>
          <table class="data-table" style={{ flex: "1", "min-width": "220px" }}>
            <thead>
              <tr><th colspan="3">Call Kinds</th></tr>
              <tr><th>Kind</th><th>Confidence</th><th>Count</th></tr>
            </thead>
            <tbody>
              <For each={tc()!.call_kind_confidence_counts}>
                {(row) => <tr><td class="name-cell">{row.kind}</td><td>{row.confidence}</td><td>{row.count}</td></tr>}
              </For>
            </tbody>
          </table>
        </div>
      </div>
    </Show>
  );
}

// ── Timeline helpers ────────────────────────────────────────────────────────

const TIMELINE_CSS = `
  .viz-root { color-scheme: light; --surface-1: #fcfcfb; --text-primary: #0b0b0b; --text-secondary: #52514e; --grid: #e3e2de; --series-1: #2a78d6; --series-2: #008300; --series-3: #e87ba4; --series-4: #eda100; --series-5: #1baf7a; --series-6: #eb6834; overflow: visible; }
  .timeline svg { display: block; }
  .gap { fill: var(--text-secondary); opacity: 0.12; stroke: var(--text-secondary); stroke-width: 1; stroke-dasharray: 4,3; }
  .phase-guide { stroke: var(--grid); stroke-width: 1; stroke-dasharray: 3,3; }
  .lane-grid { stroke: var(--grid); stroke-width: 1; }
  .phase-label, .axis-tick { fill: var(--text-secondary); font-size: 10px; }
  .lane-label { fill: var(--text-secondary); font-size: 10px; }
  .bar { opacity: 0.92; }
  .bar.series-1 { fill: var(--series-1); }
  .bar.series-2 { fill: var(--series-2); }
  .bar.series-3 { fill: var(--series-3); }
  .bar.series-4 { fill: var(--series-4); }
  .bar.series-5 { fill: var(--series-5); }
  .bar.series-6 { fill: var(--series-6); }
  @media (prefers-color-scheme: dark) {
    .viz-root { color-scheme: dark; --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --grid: #33322f; --series-1: #3987e5; --series-2: #008300; --series-3: #d55181; --series-4: #c98500; --series-5: #199e70; --series-6: #d95926; }
  }
`;

function fmtMs(ms: number | null): string {
  if (ms == null) return "—";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function fmtRows(rows: Record<string, number>): string {
  const entries = Object.entries(rows);
  if (entries.length === 0) return "—";
  return entries.map(([k, v]) => `${k}: ${v.toLocaleString()}`).join(", ");
}

type SortKey = "order" | "label" | "elapsed_ms" | "pct";

function toMarkdownTable(sorted: DiagnosticsTimelineStep[], totalMs: number, currentLabel: string | null): string {
  const header = "| Step | Duration | % Time | Input Rows | Derived Rows | Peak RES |";
  const sep = "|------|----------|--------|------------|--------------|----------|";
  const rows = sorted.map((s) => {
    const dur = s.elapsed_ms ?? 0;
    const pct = totalMs > 0 ? ((dur / totalMs) * 100).toFixed(1) : "—";
    const running = currentLabel === s.label && s.elapsed_ms == null ? " *(running)*" : "";
    return `| ${s.label}${running} | ${fmtMs(s.elapsed_ms)} | ${pct}% | ${fmtRows(s.input_rows)} | ${fmtRows(s.derived_rows)} | ${s.peak_residency_mb != null ? s.peak_residency_mb.toFixed(1) + "MB" : "—"} |`;
  });
  return [header, sep, ...rows].join("\n");
}

// ── TimelineCard ────────────────────────────────────────────────────────────

function TimelineCard(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const timeline = () => snap().diagnostics.timeline;
  const timelineRef: { el: HTMLDivElement | undefined } = { el: undefined };
  const [sortKey, setSortKey] = createSignal<SortKey>("order");
  const [sortAsc, setSortAsc] = createSignal(true);
  const [copied, setCopied] = createSignal(false);
  const [mouseX, setMouseX] = createSignal<number | null>(null);

  const zoom = () => snap().diagnostics.zoom;
  const svgContent = () => snap().diagnostics.timelineSvg;

  /** Inject the SVG into the DOM container. */
  const renderSvg = () => {
    const svg = svgContent();
    const el = timelineRef.el;
    if (!svg || !el) return;
    if (!el.querySelector("style")) {
      const styleEl = document.createElement("style");
      styleEl.textContent = TIMELINE_CSS;
      el.appendChild(styleEl);
    }
    let wrapper = el.querySelector(".viz-root") as HTMLDivElement;
    if (!wrapper) {
      wrapper = document.createElement("div");
      wrapper.className = "viz-root";
      el.appendChild(wrapper);
    }
    wrapper.innerHTML = svg;
  };

  // Re-inject SVG into DOM whenever svgContent changes
  createMemo(() => {
    svgContent();
    setTimeout(renderSvg, 0);
  });

  const allSteps = createMemo(() => {
    const t = timeline();
    if (!t) return [];
    const steps = [...t.steps];
    if (t.current) {
      steps.push({
        label: t.current.label,
        elapsed_ms: t.current.elapsed_ms,
        input_rows: t.current.input_rows,
        derived_rows: t.current.derived_rows,
        peak_residency_mb: t.current.peak_residency_mb,
        start_since_start_ms: t.current.start_since_start_ms,
        end_since_start_ms: null,
      });
    }
    return steps;
  });

  const totalMs = createMemo(() => {
    const t = timeline();
    return t?.elapsed_ms ?? allSteps().reduce((sum, s) => sum + (s.elapsed_ms ?? 0), 0);
  });

  const sorted = createMemo(() => {
    const arr = [...allSteps()];
    const asc = sortAsc();
    const key = sortKey();
    arr.sort((a, b) => {
      if (key === "order") {
        const va = a.start_since_start_ms ?? 0;
        const vb = b.start_since_start_ms ?? 0;
        return va - vb;
      }
      if (key === "label") {
        return asc ? a.label.localeCompare(b.label) : b.label.localeCompare(a.label);
      }
      let va: number;
      let vb: number;
      if (key === "elapsed_ms") {
        va = a.elapsed_ms ?? 0;
        vb = b.elapsed_ms ?? 0;
      } else {
        const tMs = totalMs();
        va = tMs > 0 ? ((a.elapsed_ms ?? 0) / tMs) : 0;
        vb = tMs > 0 ? ((b.elapsed_ms ?? 0) / tMs) : 0;
      }
      return asc ? va - vb : vb - va;
    });
    return arr;
  });

  function toggleSort(key: SortKey) {
    if (sortKey() === key) {
      setSortAsc(!sortAsc());
    } else {
      setSortKey(key);
      setSortAsc(key === "order" || key === "label");
    }
  }

  function sortIndicator(key: SortKey): string {
    if (sortKey() !== key) return "";
    return sortAsc() ? " ▲" : " ▼";
  }

  function setZoom(z: number) {
    store.dispatch({ tag: "diagnostics", action: { tag: "setZoom", zoom: z } });
  }
  function zoomIn() { setZoom(Math.min(zoom() + (zoom() >= 4 ? 1 : 0.25), 20)); }
  function zoomOut() { setZoom(Math.max(zoom() - (zoom() > 4 ? 1 : 0.25), 0.25)); }
  function zoomReset() { setZoom(1); }

  async function copyMarkdown() {
    const md = toMarkdownTable(sorted(), totalMs(), timeline()?.current?.label ?? null);
    await navigator.clipboard.writeText(md);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  // ── Crosshair: convert mouse X → elapsed time ────────────────────────────
  const LABEL_GUTTER_PX = 200;

  /** Elapsed time in ms at the current mouse position, or null if outside plot area. */
  const crosshairTime = createMemo(() => {
    const x = mouseX();
    if (x == null) return null;
    const svgEl = timelineRef.el?.querySelector("svg") as SVGSVGElement | null;
    if (!svgEl) return null;
    const renderedW = svgEl.getBoundingClientRect().width;
    if (!renderedW) return null;
    const plotRenderedW = renderedW - LABEL_GUTTER_PX;
    if (plotRenderedW <= 0 || x < LABEL_GUTTER_PX) return null;
    const pct = (x - LABEL_GUTTER_PX) / plotRenderedW;
    return Math.max(0, pct * totalMs());
  });

  function onMouseMove(e: MouseEvent) {
    const container = e.currentTarget as HTMLElement;
    const rect = container.getBoundingClientRect();
    setMouseX(e.clientX - rect.left + container.scrollLeft);
  }

  function onMouseLeave() {
    setMouseX(null);
  }

  return (
    <Show when={timeline()}>
      <div class="card" style={{ "margin-bottom": "16px" }}>
        <div class="card-header"><h2>Pipeline Timeline</h2></div>

        {/* SVG timeline graphic */}
        <Show when={svgContent()}>
          <div style={{ "display": "flex", "justify-content": "flex-end", "gap": "4px", "margin-bottom": "4px" }}>
            <button class="icon-btn" onClick={zoomOut} title="Zoom out">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </button>
            <span class="diagram-zoom-label" style={{ "min-width": "40px", "text-align": "center" }}>{Math.round(zoom() * 100)}%</span>
            <button class="icon-btn" onClick={zoomIn} title="Zoom in">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 4v8M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </button>
            <button class="icon-btn reset-btn" onClick={zoomReset} title="Reset zoom">1:1</button>
          </div>
          <div
            style={{ "position": "relative", "margin-bottom": "16px", "overflow-x": "auto" }}
            onMouseMove={onMouseMove}
            onMouseLeave={onMouseLeave}
          >
            <div
              ref={(el) => { timelineRef.el = el; renderSvg(); }}
              class="timeline"
            />
            {/* Crosshair overlay */}
            <Show when={crosshairTime() != null && mouseX() != null}>
              <div style={{
                position: "absolute",
                top: 0,
                left: `${mouseX()!}px`,
                width: "1px",
                height: "100%",
                background: "var(--text-muted)",
                opacity: 0.5,
                "pointer-events": "none",
              }} />
              <div style={{
                position: "absolute",
                top: 0,
                left: `${mouseX()!}px`,
                transform: "translateX(-50%)",
                background: snap().theme === "dark" ? "#1a1a19" : "#fcfcfb",
                border: `1px solid ${snap().theme === "dark" ? "#555" : "#ccc"}`,
                "border-radius": "3px",
                padding: "2px 6px",
                "font-size": "11px",
                color: snap().theme === "dark" ? "#fff" : "#0b0b0b",
                "white-space": "nowrap",
                "pointer-events": "none",
                "z-index": 10,
              }}>
                {fmtMs(crosshairTime())}
              </div>
            </Show>
          </div>
        </Show>

        {/* Timeline steps table */}
        <Show when={allSteps().length > 0}>
          <div style={{ "display": "flex", "justify-content": "flex-end", "margin-bottom": "8px" }}>
            <button class="filter-pill copy-btn" onClick={copyMarkdown} title="Copy table as Markdown">
              {copied() ? (
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" style={{ "vertical-align": "middle", "margin-right": "4px" }}><path d="M3 8.5l3 3 7-7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
              ) : (
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" style={{ "vertical-align": "middle", "margin-right": "4px" }}><rect x="5" y="5" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.2"/><path d="M3 11V3.5A.5.5 0 013.5 3H11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>
              )}
              {copied() ? "Copied!" : "Copy"}
            </button>
          </div>
          <table class="data-table">
            <thead>
              <tr>
                <th style={{ cursor: "pointer" }} onClick={() => toggleSort("order")}>Order{sortIndicator("order")}</th>
                <th style={{ cursor: "pointer" }} onClick={() => toggleSort("label")}>Step{sortIndicator("label")}</th>
                <th style={{ cursor: "pointer" }} onClick={() => toggleSort("elapsed_ms")}>Duration{sortIndicator("elapsed_ms")}</th>
                <th style={{ cursor: "pointer" }} onClick={() => toggleSort("pct")}>% Time{sortIndicator("pct")}</th>
                <th>Input Rows</th>
                <th>Derived Rows</th>
                <th>Peak RES</th>
              </tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(step, i) => {
                  const isRunning = step.elapsed_ms == null && timeline()?.current?.label === step.label;
                  const pct = totalMs() > 0 && step.elapsed_ms != null ? step.elapsed_ms / totalMs() : 0;
                  return (
                    <tr style={isRunning ? { "font-style": "italic", opacity: 0.85 } : {}}>
                      <td style={{ "color": "var(--text-muted)", "font-size": "11px" }}>{i() + 1}</td>
                      <td class="name-cell">
                        {step.label}
                        {isRunning && <span style={{ "margin-left": "6px", "font-size": "10px", color: "var(--text-muted)" }}>(running)</span>}
                      </td>
                      <td>{fmtMs(step.elapsed_ms)}</td>
                      <td>{pct > 0 ? `${(pct * 100).toFixed(1)}%` : "—"}</td>
                      <td>{fmtRows(step.input_rows)}</td>
                      <td>{fmtRows(step.derived_rows)}</td>
                      <td>{step.peak_residency_mb != null ? `${step.peak_residency_mb.toFixed(1)}MB` : "—"}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>
        </Show>

        <Show when={allSteps().length === 0 && !timeline()?.active}>
          <div style={{ "text-align": "center", padding: "16px", color: "var(--text-muted)" }}>
            No pipeline timeline data available. Run <code>pb index</code> to generate timeline data.
          </div>
        </Show>
      </div>
    </Show>
  );
}

// ── Main component ──────────────────────────────────────────────────────────

export function Diagnostics(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const e = () => snap().diagnostics;

  onMount(() => {
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "diagnostics" } } });
    store.dispatch({ tag: "diagnostics", action: { tag: "load" } });
  });

  function select(row: ParseErrorRow) {
    store.dispatch({ tag: "diagnostics", action: { tag: "select", row } });
  }

  function openSource(object: string, line?: number | null) {
    store.dispatch({ tag: "objects", action: { tag: "select", name: object, scrollToLine: line ?? undefined } });
  }

  const totalPages = () => Math.max(1, Math.ceil(e().total / PAGE_SIZE));

  return (
    <>
      <TypeCoverageCard store={store} />
      <TimelineCard store={store} />

      <div class="card">
      <div class="card-header"><h2>Diagnostics</h2></div>

      <div class="filter-pills">
        <For each={KIND_FILTERS}>
          {(f) => (
            <button
              class={`filter-pill ${e().filterKind === f.value ? "active" : ""}`}
              onClick={() => store.dispatch({ tag: "diagnostics", action: { tag: "setFilterKind", kind: f.value } })}
            >
              {f.label}
            </button>
          )}
        </For>
        <input
          class="search-input"
          placeholder="Search message / file / snippet"
          value={e().query}
          onInput={(ev) => store.dispatch({ tag: "diagnostics", action: { tag: "setQuery", query: ev.currentTarget.value } })}
        />
      </div>

      <table class="data-table">
        <thead>
          <tr>
            <th>File</th>
            <th>Kind</th>
            <th>Line</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <Show when={!e().loading}>
            <For each={e().items}>
              {(row) => (
                <tr class="error-list-item" onClick={() => select(row)}>
                  <td class="name-cell">
                    <Show
                      when={row.object}
                      fallback={<span>{row.file}</span>}
                    >
                      <button
                        class="link-btn"
                        onClick={(ev) => { ev.stopPropagation(); openSource(row.object!, row.line); }}
                        title="Open source at error line"
                      >
                        {row.file}
                      </button>
                    </Show>
                  </td>
                  <td>{row.error_kind}</td>
                  <td>{row.line ?? ""}</td>
                  <td>{row.message}</td>
                </tr>
              )}
            </For>
          </Show>
        </tbody>
      </table>

      <Show when={e().loading}>
        <div style={{ "text-align": "center", padding: "12px", color: "var(--text-muted)" }}>Loading...</div>
      </Show>

      <Show when={e().total > PAGE_SIZE}>
        <div class="pagination" style={{ "display": "flex", "gap": "8px", "align-items": "center", "justify-content": "center", "margin-top": "8px" }}>
          <button
            class="filter-pill"
            disabled={e().page === 0}
            onClick={() => store.dispatch({ tag: "diagnostics", action: { tag: "setPage", page: e().page - 1 } })}
          >Prev</button>
          <span style={{ "font-size": "12px", color: "var(--text-muted)" }}>
            Page {e().page + 1} of {totalPages()} ({e().total} total)
          </span>
          <button
            class="filter-pill"
            disabled={e().page >= totalPages() - 1}
            onClick={() => store.dispatch({ tag: "diagnostics", action: { tag: "setPage", page: e().page + 1 } })}
          >Next</button>
        </div>
      </Show>

      <Show when={e().total > 0 && !e().loading}>
        <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
          {e().total} error(s)
        </div>
      </Show>

      <Show when={e().selected}>
        {(() => {
          const row = e().selected!;
          const baseLine = row.error_kind === "sql" ? (row.line ?? 1) : 1;
          const rawSnippet = () => row.snippet ?? row.message;
          const anonSnippet = createMemo(() => anonymizeText(rawSnippet()));
          const anonMessage = createMemo(() => anonymizeText(row.message));

          const isSql = row.error_kind === "sql";

          return (
            <div class="card" style={{ "margin-top": "16px" }}>
              <Tabs defaultValue="raw">
                <Tabs.List class="tab-bar">
                  <Tabs.Trigger value="raw" class="tab-btn">Raw</Tabs.Trigger>
                  <Tabs.Trigger value="anonymized" class="tab-btn">Anonymized</Tabs.Trigger>
                  {isSql && <Tabs.Trigger value="file-context" class="tab-btn">File Context</Tabs.Trigger>}
                </Tabs.List>

                <Tabs.Content value="raw">
                  <div class="error-detail-header">
                    <p>{row.message}</p>
                    <CopyButton text={rawSnippet()} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={row.snippet!} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>

                <Tabs.Content value="anonymized">
                  <div class="error-detail-header">
                    <p>{anonMessage()}</p>
                    <CopyButton text={anonSnippet()} />
                  </div>
                  <Show when={row.snippet}>
                    <CodeBlock code={anonSnippet()} baseLine={baseLine} highlightLine={row.line ?? undefined} />
                  </Show>
                </Tabs.Content>

                {isSql && (
                  <Tabs.Content value="file-context">
                    <DiagnosticsFileContext row={row} />
                  </Tabs.Content>
                )}
              </Tabs>
            </div>
          );
        })()}
      </Show>

      </div>
    </>
  );
}

function DiagnosticsFileContext(props: { row: ParseErrorRow }) {
  const [raw] = createResource(
    () => props.row.file,
    (file) => fetch("/api/diagnostics/source?file=" + encodeURIComponent(file))
      .then(r => r.json() as Promise<{ lines: string[] }>),
    { initialValue: { lines: [] as string[] } },
  );

  const [highlighted] = createResource(
    () => raw()?.lines,
    (lines) => {
      if (!lines || lines.length === 0) return Promise.resolve("");
      return highlightAsync(lines.join("\n"));
    },
    { initialValue: "" },
  );

  const line = () => props.row.line ?? 1;

  return (
    <div>
      <div class="error-detail-header">
        <p>Full file source — error at line {line()}</p>
      </div>
      <Show
        when={!highlighted.loading && highlighted()}
        fallback={<div class="loading-overlay"><div class="spinner" /> Loading file source...</div>}
      >
        <CodeBlock code={highlighted()!} baseLine={1} highlightLine={line()} />
      </Show>
    </div>
  );
}
