export function ErrorBanner(props: { children: string }) {
  return (
    <div class="error-banner" style={{ color: "var(--red)", padding: "12px 16px" }}>
      {props.children}
    </div>
  );
}
