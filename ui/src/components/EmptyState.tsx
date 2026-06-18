export function EmptyState(props: { children: string; class?: string }) {
  return (
    <div class={props.class ?? "muted-note"} style={{ "text-align": "center", padding: "16px", color: "var(--text-muted)", "font-size": "13px" }}>
      {props.children}
    </div>
  );
}
