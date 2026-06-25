export function debounce<T extends (...args: never[]) => void>(fn: T, ms: number): T {
  let timer: ReturnType<typeof setTimeout>;
  return ((...args: never[]) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); }) as T;
}
