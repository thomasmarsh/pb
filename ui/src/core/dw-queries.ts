// dw-queries.ts — SQL templates keyed by DataWindow control name.

export interface SQLResult {
  rows: Record<string, unknown>[];
  columns: string[];
  rowcount: number;
  error?: string;
}

export const DW_QUERIES: Record<string, string> = {
  dw_misth_zpperiod_list: `
    SELECT kodperiod, descperiod, orderno
    FROM misth_zpperiod
    WHERE kodxrisi = ?
    ORDER BY orderno
  `,
  dw_misth_zpkrat_form: `
    SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos
    FROM misth_zpkrat
    WHERE kodkrat = ? AND kodxrisi = ?
  `,
  dw_misth_zpkrat_list: `
    SELECT kodkrat, desckrat
    FROM misth_zpkrat
    WHERE kodxrisi = ?
    ORDER BY kodkrat
  `,
  dw_misth_ypal_list: `
    SELECT kodypal, lastname, firstname
    FROM misth_ypal
    WHERE kodxrisi = ?
    ORDER BY lastname, firstname
  `,
};
