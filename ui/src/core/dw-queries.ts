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
  // w_list subclass list windows — all filter by arg_kodxrisi (bound to gs_kodxrisi)
  dw_misth_zpkrat_list: `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat WHERE kodxrisi = ? ORDER BY kodkrat LIMIT 100`,
  dw_misth_ypal_list:   `SELECT y.kodypal, y.kodxrisi, y.surname, y.name, y.fathername, y.mitroo, y.klimakio, y.klados, y.bathmos, i.descidikot FROM misth_ypal y LEFT JOIN misth_zpidikot i ON y.kodidikot = i.kodidikot AND i.kodxrisi = y.kodxrisi WHERE y.kodxrisi = ? ORDER BY y.surname, y.name LIMIT 100`,
  dw_misth_zpepidom_list: `SELECT kodepidom, kodxrisi, descepidom, hasforo, isasf, autoforos, hasasf FROM misth_zpepidom WHERE kodxrisi = ? ORDER BY descepidom LIMIT 100`,
  dw_misth_final_list:  `SELECT f.kodfinal, f.kodxrisi, f.descfinal, f.datefinal, f.title, f.kodkat, k.desckat, f.kodperiod, p.descperiod, f.aa FROM misth_final f LEFT JOIN misth_zpkat k ON f.kodkat = k.kodkat AND k.kodxrisi = f.kodxrisi LEFT JOIN misth_zpperiod p ON f.kodperiod = p.kodperiod AND p.kodxrisi = f.kodxrisi WHERE f.kodxrisi = ? ORDER BY f.datefinal ASC LIMIT 100`,
  // Used by w_krat_total_search open event — WHERE clause uses gs_kodxrisi param
  dw_krat:   `SELECT kodkrat, kodxrisi, desckrat, isforos, isasf, isautoforos FROM misth_zpkrat WHERE kodxrisi = ? ORDER BY kodkrat LIMIT 100`,
  dw_period: `SELECT kodperiod, descperiod, orderno FROM misth_zpperiod WHERE kodxrisi = ? ORDER BY orderno LIMIT 100`,
  // Child DataWindows retrieved via fn_retrievechild(adw, "col", gs_kodxrisi)
  child_kodperiod: `SELECT kodperiod, descperiod FROM misth_zpperiod WHERE kodxrisi = ? ORDER BY orderno`,
  child_kodkat:    `SELECT kodkrat, desckrat FROM misth_zpkrat WHERE kodxrisi = ? ORDER BY kodkrat`,
};
