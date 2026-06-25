// features/analysis/AnalysisView.tsx — Shared chrome for all Analysis View templates.

import { createSignal } from "solid-js";
import type { JSX } from "solid-js";
import { ChevronDown, ChevronRight } from "@pb/platform";

interface AnalysisViewProps {
  title: string;
  contextLabel: string;
  assumptions?: string;
  children: JSX.Element;
}

export function AnalysisView(props: AnalysisViewProps): JSX.Element {
  const [showAssumptions, setShowAssumptions] = createSignal(false);

  return (
    <div class="analysis-view">
      <div class="analysis-title-bar">
        <span class="analysis-title">{props.title}</span>
        <span class="analysis-context-label">{props.contextLabel}</span>
        <button class="analysis-save-btn" title="Save this view (not yet implemented)">
          Save this view
        </button>
      </div>

      {props.children}

      <div class="analysis-phase-footer">
        {props.assumptions && (
          <>
            <button
              class="analysis-assumptions-toggle"
              onClick={() => setShowAssumptions((v) => !v)}
              aria-expanded={showAssumptions()}
            >
              <span>{showAssumptions() ? <ChevronDown size={12} /> : <ChevronRight size={12} />}</span> Assumptions
            </button>
            {showAssumptions() && (
              <p class="analysis-assumptions-body">{props.assumptions}</p>
            )}
          </>
        )}
      </div>
    </div>
  );
}
