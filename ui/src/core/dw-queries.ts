// dw-queries.ts — SQL templates keyed by DataWindow control name.

export interface SQLResult {
  rows: Record<string, unknown>[];
  columns: string[];
  rowcount: number;
  error?: string;
}

// Preview-mode queries: no WHERE filters so data shows regardless of global variable state.
export const DW_QUERIES: Record<string, string> = {
  dw_misth_zpperiod_list: `SELECT kodperiod, descperiod, orderno FROM misth_zpperiod ORDER BY orderno LIMIT 100`,
  dw_misth_zpkrat_form:   `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat LIMIT 1`,
  dw_misth_zpkrat_list:   `SELECT kodkrat, desckrat FROM misth_zpkrat ORDER BY kodkrat LIMIT 100`,
  dw_misth_ypal_list:     `SELECT kodypal, lastname, firstname FROM misth_ypal ORDER BY lastname, firstname LIMIT 100`,
  // Used by w_krat_total_search open event
  dw_krat:   `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat ORDER BY kodkrat LIMIT 100`,
  dw_period: `SELECT kodperiod, descperiod, orderno FROM misth_zpperiod ORDER BY orderno LIMIT 100`,
};
