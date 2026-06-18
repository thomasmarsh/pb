import type { JSX } from "solid-js";

interface SectionLabelProps {
  children: string;
  count?: number;
  style?: JSX.CSSProperties;
}

export function SectionLabel(props: SectionLabelProps): JSX.Element {
  const label = () => props.count != null ? `${props.children} (${props.count})` : props.children;
  return (
    <div class="section-label" style={{ "margin-bottom": "4px", ...props.style }}>
      {label()}
    </div>
  );
}
