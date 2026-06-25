// components/windows/MenuBar.tsx — Horizontal menu bar shell for MDI frame.
// Stub with data model; no PB menu parsing yet.

import { createSignal, createEffect, For, Show, onCleanup, type JSX } from "solid-js";

export interface MenuItem {
  label: string;
  accelerator?: string;
  action?: () => void;
  separator?: boolean;
  submenu?: MenuItem[];
}

interface MenuBarProps {
  items: MenuItem[];
}

function MenuDropdown(props: {
  items: MenuItem[];
  onClose: () => void;
}): JSX.Element {
  return (
    <div class="wm-menu-dropdown" role="menu">
      <For each={props.items}>
        {(item) => {
          if (item.separator) {
            return <div class="wm-menu-separator" role="separator" />;
          }
          return (
            <button
              class="wm-menu-item"
              role="menuitem"
              onClick={() => { item.action?.(); props.onClose(); }}
            >
              <span class="wm-menu-label">{item.label}</span>
              <Show when={item.accelerator}>
                <span class="wm-menu-accel">{item.accelerator}</span>
              </Show>
            </button>
          );
        }}
      </For>
    </div>
  );
}

export function MenuBar(props: MenuBarProps): JSX.Element {
  const [openMenu, setOpenMenu] = createSignal<string | null>(null);

  function handleClickOutside(e: MouseEvent): void {
    const target = e.target as HTMLElement;
    if (!target.closest(".wm-menubar")) {
      setOpenMenu(null);
    }
  }

  function handleKeyDown(e: KeyboardEvent): void {
    if (e.key === "Escape") setOpenMenu(null);
  }

  createEffect(() => {
    if (openMenu()) {
      document.addEventListener("click", handleClickOutside);
      document.addEventListener("keydown", handleKeyDown);
      onCleanup(() => {
        document.removeEventListener("click", handleClickOutside);
        document.removeEventListener("keydown", handleKeyDown);
      });
    }
  });

  return (
    <nav class="wm-menubar" role="menubar">
      <For each={props.items}>
        {(item) => (
          <div class="wm-menu-container">
            <button
              class={`wm-menu-trigger${openMenu() === item.label ? " active" : ""}`}
              role="menuitem"
              aria-haspopup="true"
              aria-expanded={openMenu() === item.label}
              onClick={() => setOpenMenu(openMenu() === item.label ? null : item.label)}
              onMouseEnter={() => { if (openMenu()) setOpenMenu(item.label); }}
            >
              {item.label}
            </button>
            <Show when={openMenu() === item.label && item.submenu}>
              {(sub) => (
                <MenuDropdown items={sub()} onClose={() => setOpenMenu(null)} />
              )}
            </Show>
          </div>
        )}
      </For>
    </nav>
  );
}
