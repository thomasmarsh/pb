// components/detail/AnalysisExplainer.tsx — Reusable "what is this and how do
// I read it" modal for analysis panels that aren't self-explanatory (heat
// matrices, dendrograms, schema graphs). Content is authored per-feature and
// colocated with the panel it explains (e.g. ColumnAffinityCore.tsx exports
// its own AnalysisExplainerContent); this component only renders the shape.

import { For } from "solid-js";
import type { JSX } from "solid-js";
import { ModalShell } from "../ui/ModalShell.js";

export interface AnalysisExplainerContent {
  title: string;
  whatItIs: string;
  howItsUsed: string;
  tips: string[];
  // A thunk, not a pre-built JSX.Element — keeps the fake-data example's
  // render inside this component's own reactive scope instead of module
  // scope, and mirrors how Show/For already take children as functions.
  example: () => JSX.Element;
}

interface AnalysisExplainerProps {
  open: boolean;
  onClose: () => void;
  content: AnalysisExplainerContent;
}

export function AnalysisExplainer(props: AnalysisExplainerProps): JSX.Element {
  return (
    <ModalShell open={props.open} onClose={props.onClose} label={props.content.title} width="640px">
      <div class="help-panel-header">
        <h2>{props.content.title}</h2>
        <button class="help-close-btn" onClick={props.onClose} aria-label="Close">×</button>
      </div>
      <div class="explainer-body">
        <section class="explainer-section">
          <h4>What it is</h4>
          <p>{props.content.whatItIs}</p>
        </section>
        <section class="explainer-section">
          <h4>How it's used</h4>
          <p>{props.content.howItsUsed}</p>
        </section>
        <section class="explainer-section">
          <h4>Example</h4>
          <div class="explainer-example">{props.content.example()}</div>
        </section>
        <section class="explainer-section">
          <h4>Tips</h4>
          <ul class="explainer-tips">
            <For each={props.content.tips}>{(tip) => <li>{tip}</li>}</For>
          </ul>
        </section>
      </div>
    </ModalShell>
  );
}
