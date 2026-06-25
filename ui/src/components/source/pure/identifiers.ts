import { PB_KEYWORDS } from "@pb/platform";
import type { KnownProcInfo, LocalSymbolInfo } from "@pb/platform";

export function linkIdentifiers(
  html: string,
  objectMap: Map<string, { name: string; kind: string }>,
  procMap: Map<string, KnownProcInfo>,
  varMap: Map<string, LocalSymbolInfo>,
  selfName: string,
): string {
  return html.replace(/\b([A-Za-z_][\w$#%-]*)\b/g, (match, word) => {
    const lower = word.toLowerCase();
    if (lower === selfName.toLowerCase()) return match;
    if (PB_KEYWORDS.has(lower)) return match;
    if (procMap.has(lower)) {
      return `<span class="src-link src-link-proc" data-link-type="procedure" data-link-name="${word}">${match}</span>`;
    }
    if (varMap.has(lower)) {
      const sym = varMap.get(lower)!;
      const cls = sym.is_parameter ? "src-link-param" : "src-link-var";
      return `<span class="src-link ${cls}" data-link-type="var" data-link-name="${word}">${match}</span>`;
    }
    if (objectMap.has(lower)) {
      return `<span class="src-link src-link-obj" data-link-type="object" data-link-name="${word}">${match}</span>`;
    }
    return match;
  });
}
