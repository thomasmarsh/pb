import { createSignal } from "solid-js";

interface SvgToolbarProps {
  onCopy?: () => void;
  onDownload?: () => void;
  downloadFilename?: string;
  // Zoom controls appear only when a viewport is driving them. Diagrams
  // rendered at their natural size (no pan/zoom wrapper) omit these and get
  // the copy/download pair alone, as before.
  onZoomIn?: () => void;
  onZoomOut?: () => void;
  onResetView?: () => void;
  scale?: () => number;
}

export function SvgToolbar(props: SvgToolbarProps) {
  const [copied, setCopied] = createSignal(false);

  function handleCopy() {
    props.onCopy?.();
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  return (
    <div class="diagram-toolbar">
      {props.onZoomOut && (
        <button class="icon-btn" onClick={props.onZoomOut} title="Zoom out">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
        </button>
      )}
      {props.scale && <span class="diagram-zoom-label">{Math.round(props.scale() * 100)}%</span>}
      {props.onZoomIn && (
        <button class="icon-btn" onClick={props.onZoomIn} title="Zoom in">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 4v8M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
        </button>
      )}
      {props.onResetView && (
        <button class="icon-btn reset-btn" onClick={props.onResetView} title="Reset zoom">1:1</button>
      )}
      {props.onZoomOut && (props.onCopy || props.onDownload) && <span class="diagram-toolbar-sep" />}
      {props.onCopy && (
        <button class="icon-btn" onClick={handleCopy} title="Copy SVG">
          {copied() ? (
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8.5l3 3 7-7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
          ) : (
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><rect x="5" y="5" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.2"/><path d="M3 11V3.5A.5.5 0 013.5 3H11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>
          )}
        </button>
      )}
      {props.onDownload && (
        <button class="icon-btn" onClick={props.onDownload} title="Download SVG">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 2v8m0 0l-3-3m3 3l3-3M3 12.5h10" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></svg>
        </button>
      )}
    </div>
  );
}
