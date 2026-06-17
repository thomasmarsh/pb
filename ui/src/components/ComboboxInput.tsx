// ComboboxInput.tsx — Reusable typeahead combobox backed by an item list.

import { Combobox } from "@kobalte/core/combobox";
import type { CollectionNode } from "@kobalte/core";

function OptionItem(props: { item: CollectionNode<string> }) {
  return (
    <Combobox.Item item={props.item}>
      <Combobox.ItemLabel>{props.item.rawValue}</Combobox.ItemLabel>
    </Combobox.Item>
  );
}

export interface ComboboxInputProps {
  value: string;
  onChange: (value: string) => void;
  options: string[];
  placeholder?: string;
  onEnter?: () => void;
}

export function ComboboxInput(props: ComboboxInputProps) {
  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter" && props.onEnter) {
      e.preventDefault();
      props.onEnter!();
    }
  }

  return (
    <Combobox
      value={props.value}
      onChange={(v) => props.onChange(v ?? "")}
      options={props.options}
      optionValue={(opt) => opt}
      optionLabel={(opt) => opt}
      optionTextValue={(opt) => opt}
      placeholder={props.placeholder ?? "Type to search…"}
      class="combobox-wrapper"
      itemComponent={OptionItem}
    >
      <Combobox.Control class="combobox-control">
        <Combobox.Input class="search-input" onKeyDown={handleKeyDown as any} />
      </Combobox.Control>
      <Combobox.Portal>
        <Combobox.Content class="combobox-content">
          <Combobox.Listbox class="combobox-listbox" />
        </Combobox.Content>
      </Combobox.Portal>
    </Combobox>
  );
}
