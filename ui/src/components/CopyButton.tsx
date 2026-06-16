// CopyButton.tsx — Small button that copies given text to the clipboard.

import { createSignal } from "solid-js";

export function CopyButton(props: { text: string }) {
  const [copied, setCopied] = createSignal(false);

  function handleClick() {
    navigator.clipboard.writeText(props.text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }

  return (
    <button class="filter-pill copy-btn" onClick={handleClick}>
      {copied() ? "Copied!" : "Copy"}
    </button>
  );
}
