// dw-queries.ts — SQL templates keyed by DataWindow control name.

export interface SQLResult {
  rows: Record<string, unknown>[];
  columns: string[];
  rowcount: number;
  error?: string;
}

export const DW_QUERIES: Record<string, string> = {
  dw_misth_zpperiod_list: `SELECT kodperiod, descperiod, orderno FROM misth_zpperiod ORDER BY orderno LIMIT 100`,
  dw_misth_zpkrat_form:   `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat LIMIT 1`,
  dw_misth_zpkrat_list:   `SELECT kodkrat, desckrat FROM misth_zpkrat ORDER BY kodkrat LIMIT 100`,
  dw_misth_ypal_list:     `SELECT kodypal, lastname, firstname FROM misth_ypal ORDER BY lastname, firstname LIMIT 100`,
  // Used by w_krat_total_search open event — WHERE clause uses gs_kodxrisi param
  dw_krat:   `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat WHERE kodxrisi = ? ORDER BY kodkrat LIMIT 100`,
  dw_period: `SELECT kodperiod, descperiod, orderno FROM misth_zpperiod WHERE kodxrisi = ? ORDER BY orderno LIMIT 100`,
  // Child DataWindows retrieved via fn_retrievechild(adw, "col", gs_kodxrisi)
  child_kodperiod: `SELECT kodperiod, descperiod FROM misth_zpperiod WHERE kodxrisi = ? ORDER BY orderno`,
  child_kodkat:    `SELECT kodkrat, desckrat FROM misth_zpkrat WHERE kodxrisi = ? ORDER BY kodkrat`,
};
