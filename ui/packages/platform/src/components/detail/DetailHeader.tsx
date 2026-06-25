import type { JSX } from "solid-js";

interface DetailHeaderProps {
  name: string;
  badgeClass: string;
  badgeLabel: string;
  subtitle?: JSX.Element;
}

export function DetailHeader(props: DetailHeaderProps): JSX.Element {
  return (
    <div class="detail-header">
      <div>
        <h2 style={{ "margin": "0", "font-size": "20px" }}>
          {props.name} <span class={`badge ${props.badgeClass}`}>{props.badgeLabel}</span>
        </h2>
        {props.subtitle}
      </div>
    </div>
  );
}
