import type { JSX } from "solid-js";

interface ContextualPanelProps {
  title: string;
  onClose: () => void;
  onHelp?: () => void;
  children: JSX.Element;
}

export function ContextualPanel(props: ContextualPanelProps): JSX.Element {
  return (
    <div class="card" style={{ "margin-top": "12px" }}>
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h3 style={{ flex: 1, margin: 0 }}>{props.title}</h3>
        {props.onHelp && (
          <button
            onClick={props.onHelp}
            aria-label="What is this?"
            title="What is this?"
            style={{
              background: "none",
              border: "none",
              cursor: "pointer",
              color: "var(--text-muted)",
              "font-size": "14px",
              padding: "0 4px",
              "line-height": "1",
            }}
          >
            ⓘ
          </button>
        )}
        <button
          onClick={props.onClose}
          aria-label="Close panel"
          style={{
            background: "none",
            border: "none",
            cursor: "pointer",
            color: "var(--text-muted)",
            "font-size": "16px",
            padding: "0 4px",
            "line-height": "1",
          }}
        >
          ✕
        </button>
      </div>
      <div>{props.children}</div>
    </div>
  );
}
