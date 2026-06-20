// runtime.ts — PB built-in function library.

export type PBFunction = (...args: unknown[]) => unknown;

export const PB_BUILTINS: Record<string, PBFunction> = {
  // String functions (PB uses 1-based indexing)
  mid: (str, start, len) => {
    const s = String(str);
    const st = Number(start) - 1;
    return len != null ? s.substring(st, st + Number(len)) : s.substring(st);
  },
  left: (str, len) => String(str).substring(0, Number(len)),
  right: (str, len) => String(str).slice(-Number(len)),
  len: (str) => String(str).length,
  pos: (str, search) => String(str).indexOf(String(search)) + 1,
  trim: (str) => String(str).trim(),
  upper: (str) => String(str).toUpperCase(),
  lower: (str) => String(str).toLowerCase(),
  space: (n) => " ".repeat(Math.max(0, Number(n))),
  fill: (n, ch) => String(ch).repeat(Math.max(0, Number(n))),
  reverse: (str) => String(str).split("").reverse().join(""),
  replace: (str, from, to) => String(str).split(String(from)).join(String(to)),

  // Type conversions
  string: (val) => String(val),
  integer: (val) => parseInt(String(val), 10) || 0,
  long: (val) => parseInt(String(val), 10) || 0,
  real: (val) => parseFloat(String(val)) || 0,
  dec: (val) => parseFloat(String(val)) || 0,
  char: (code) => String.fromCharCode(Number(code)),

  // Null / type checks
  isnull: (val) => val === null || val === undefined,
  isnumber: (val) => !isNaN(Number(val)) && val !== null && val !== undefined,
  isdate: () => false, // stub
  istime: () => false, // stub

  // Numeric
  abs: (val) => Math.abs(Number(val)),
  mod: (a, b) => Number(a) % Number(b),
  max: (a, b) => Math.max(Number(a), Number(b)),
  min: (a, b) => Math.min(Number(a), Number(b)),
  round: (val, dec) => {
    const f = Math.pow(10, Number(dec));
    return Math.round(Number(val) * f) / f;
  },
  ceiling: (val) => Math.ceil(Number(val)),
  floor: (val) => Math.floor(Number(val)),
  sign: (val) => Math.sign(Number(val)),

  // Color
  rgb: (r, g, b) => (Number(r) << 16) | (Number(g) << 8) | Number(b),

  // Translation stubs (real lookup in 101c)
  trn: (id) => `[${id}]`,
  tr: (id) => `[${id}]`,

  // MessageBox stub (alert in browser, no-op in tests)
  messagebox: (_title, _text, _icon, _button) => {
    if (typeof window !== "undefined" && typeof window.alert === "function") {
      window.alert(`${_title}: ${_text}`);
    }
  },

  // DataWindow stubs (mock retrieve in 101b)
  retrieve: () => [] as unknown[],
};
