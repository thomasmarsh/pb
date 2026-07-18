// tests/objects/detail/SourceCard.test.tsx — Tests for SourceCard's slice-highlight wiring (Plan 174 T0-2).

import { describe, it, expect } from "vitest";
import { render, fireEvent } from "@solidjs/testing-library";
import { SourceCard } from "../../../app/src/views/features/objects/detail/SourceCard.js";
import { createTestStore } from "../../helpers.js";
import { initialObjectsState } from "@pb/platform";
import type { ObjectSourceResponse, SliceResult } from "@pb/platform";

const sourceDetail: ObjectSourceResponse = {
  file: "w_foo.srw",
  lines: ["ls_x = 1", "ls_x = 2", "ls_x = 3"],
  procedures: [],
  knownObjects: [],
  knownProcs: [],
};

describe("SourceCard slice highlight", () => {
  it("renders no banner when sliceHighlight is absent", () => {
    const { store } = createTestStore({
      objects: { ...initialObjectsState, sourceDetail },
    });
    render(() => (
      <SourceCard store={store} file="w_foo.srw" objectName="w_foo" sourceDetail={sourceDetail} />
    ));
    expect(document.querySelector(".source-slice-banner")).toBeNull();
  });

  it("renders the banner and dims non-slice lines for the matching object", () => {
    const sliceData: SliceResult = {
      origin: { object: "w_foo", proc: "of_bar", line: 2, var: "ls_x" },
      direction: "backward",
      steps: [{ object: "w_foo", proc: "of_bar", line: 2, var: "ls_x", kind: "definition", text: "ls_x = 2" }],
      procedures_traversed: ["w_foo.of_bar"],
    };
    const { store } = createTestStore({
      objects: { ...initialObjectsState, sourceDetail, sliceHighlight: { ...sliceData, object: "w_foo", proc: "of_bar" } },
    });
    render(() => (
      <SourceCard store={store} file="w_foo.srw" objectName="w_foo" sourceDetail={sourceDetail} />
    ));
    const banner = document.querySelector(".source-slice-banner");
    expect(banner).not.toBeNull();
    expect(banner?.textContent).toContain("of_bar:2");
    expect(banner?.textContent).toContain("1 statement");
    // Line 2 is highlighted; lines 1 and 3 dim.
    expect(document.querySelectorAll(".source-code-line--dim").length).toBe(2);
  });

  it("does not surface a highlight computed for a different object", () => {
    const sliceData: SliceResult = {
      origin: { object: "w_other", proc: "of_bar", line: 2, var: "ls_x" },
      direction: "backward",
      steps: [{ object: "w_other", proc: "of_bar", line: 2, var: "ls_x", kind: "definition", text: "ls_x = 2" }],
      procedures_traversed: ["w_other.of_bar"],
    };
    const { store } = createTestStore({
      objects: { ...initialObjectsState, sourceDetail, sliceHighlight: { ...sliceData, object: "w_other", proc: "of_bar" } },
    });
    render(() => (
      <SourceCard store={store} file="w_foo.srw" objectName="w_foo" sourceDetail={sourceDetail} />
    ));
    expect(document.querySelector(".source-slice-banner")).toBeNull();
  });

  it("Clear button dispatches clear-slice-highlight", () => {
    const sliceData: SliceResult = {
      origin: { object: "w_foo", proc: "of_bar", line: 2, var: "ls_x" },
      direction: "backward",
      steps: [{ object: "w_foo", proc: "of_bar", line: 2, var: "ls_x", kind: "definition", text: "ls_x = 2" }],
      procedures_traversed: ["w_foo.of_bar"],
    };
    const { store, captured } = createTestStore({
      objects: { ...initialObjectsState, sourceDetail, sliceHighlight: { ...sliceData, object: "w_foo", proc: "of_bar" } },
    });
    render(() => (
      <SourceCard store={store} file="w_foo.srw" objectName="w_foo" sourceDetail={sourceDetail} />
    ));
    const btn = document.querySelector(".source-slice-banner button")!;
    fireEvent.click(btn);
    expect(captured.some((a) =>
      a.tag === "objects" && "action" in a && (a as any).action.tag === "clear-slice-highlight"
    )).toBe(true);
  });
});
