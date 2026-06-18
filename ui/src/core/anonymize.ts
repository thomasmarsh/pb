// anonymize.ts — length-preserving identifier masking for sharing error snippets.
//
// Tokenizes identifier-shaped runs, leaves PowerBuilder/SQL keywords and all
// non-alphanumeric bytes (punctuation, whitespace, underscores) untouched, and
// replaces each remaining letter/digit with a random one of the same class.
// The same exact token text always maps to the same replacement within one call.

import { PB_KEYWORDS } from "../utils/highlight.js";

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const LOWER = "abcdefghijklmnopqrstuvwxyz";
const DIGITS = "0123456789";

function randomChar(alphabet: string): string {
  return alphabet[Math.floor(Math.random() * alphabet.length)]!;
}

function maskToken(token: string): string {
  let out = "";
  for (const ch of token) {
    if (ch >= "A" && ch <= "Z") out += randomChar(UPPER);
    else if (ch >= "a" && ch <= "z") out += randomChar(LOWER);
    else if (ch >= "0" && ch <= "9") out += randomChar(DIGITS);
    else out += ch;
  }
  return out;
}

const IDENTIFIER_RE = /\b[A-Za-z_][A-Za-z0-9_]*\b/g;

export function anonymizeText(text: string): string {
  const replacements = new Map<string, string>();
  return text.replace(IDENTIFIER_RE, (token) => {
    if (PB_KEYWORDS.has(token.toLowerCase())) return token;
    let replacement = replacements.get(token);
    if (replacement === undefined) {
      replacement = maskToken(token);
      replacements.set(token, replacement);
    }
    return replacement;
  });
}
