// tests/objects/detail/StructuresCard.test.tsx — Tests for StructuresCard component.

import { describe, it, expect, afterEach } from "vitest";
import { screen, render, cleanup } from "@solidjs/testing-library";
import { StructuresCard } from "../../../app/src/views/features/objects/detail/StructuresCard.js";

// This file renders without `../../helpers.js` (StructuresCard takes no
// store), so it must register cleanup itself -- helpers.tsx normally does
// this as a side effect of import.
afterEach(() => cleanup());

const sampleStructures = [
  {
    name: "s_fish",
    fields: [
      { var_name: "species", var_type: "string", modifiers: null },
      { var_name: "weight", var_type: "decimal", modifiers: "public" },
    ],
  },
];

describe("StructuresCard", () => {
  it("shows total structure count in header", () => {
    render(() => <StructuresCard structures={sampleStructures} />);
    expect(screen.getByText("Structures (1)")).toBeDefined();
  });

  it("renders structure name with field count", () => {
    render(() => <StructuresCard structures={sampleStructures} />);
    expect(screen.getByText("s_fish (2)")).toBeDefined();
  });

  it("renders field names, types, and modifiers", () => {
    render(() => <StructuresCard structures={sampleStructures} />);
    expect(screen.getByText("species")).toBeDefined();
    expect(screen.getByText("string")).toBeDefined();
    expect(screen.getByText("weight")).toBeDefined();
    expect(screen.getByText("decimal")).toBeDefined();
    expect(screen.getByText("public")).toBeDefined();
  });

  it("shows empty-fields fallback for a structure with no fields", () => {
    render(() => <StructuresCard structures={[{ name: "s_empty", fields: [] }]} />);
    expect(screen.getByText("No fields.")).toBeDefined();
  });

  it("renders multiple structures", () => {
    render(() => (
      <StructuresCard
        structures={[
          { name: "s_fish", fields: [{ var_name: "species", var_type: "string", modifiers: null }] },
          { name: "s_tank", fields: [{ var_name: "volume", var_type: "decimal", modifiers: null }] },
        ]}
      />
    ));
    expect(screen.getByText("Structures (2)")).toBeDefined();
    expect(screen.getByText("s_fish (1)")).toBeDefined();
    expect(screen.getByText("s_tank (1)")).toBeDefined();
  });
});
