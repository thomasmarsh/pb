// tests/mock-runtime-env.ts — Mock RuntimeEnv that captures SQL calls and returns controlled data.

import { Effect, type SQLResult } from "@pb/core";
import type { RuntimeEnv } from "@pb/windowing";

export interface MockRuntimeEnv extends RuntimeEnv {
  /** Last SQL executed. */
  lastSql: string | null;
  lastParams: unknown[] | null;
  /** Controlled responses keyed by SQL table pattern. */
  responses: Map<string, SQLResult>;
  /** All SQL calls made. */
  calls: Array<{ sql: string; params: unknown[] }>;
}

export function createMockRuntimeEnv(
  defaults?: Partial<Record<string, SQLResult>>,
): MockRuntimeEnv {
  const env: MockRuntimeEnv = {
    lastSql: null,
    lastParams: null,
    responses: new Map(Object.entries(defaults ?? {}) as [string, SQLResult][]),
    calls: [],

    getDwQueries: () => Effect.none(),

    executeSql: (sql: string, params: unknown[]) => {
      env.lastSql = sql;
      env.lastParams = params;
      env.calls.push({ sql, params });

      for (const [pattern, result] of env.responses) {
        if (sql.toLowerCase().includes(pattern.toLowerCase())) {
          return Effect.send(result);
        }
      }
      return Effect.send({ rows: [], rowcount: 0, columns: [] });
    },
  };
  return env;
}

/** Preset for openpay windows — covers all DW_QUERIES tables. */
export function createOpenpayMockEnv(): MockRuntimeEnv {
  return createMockRuntimeEnv({
    misth_zpkrat: {
      rows: [
        { kodkrat: "01", kodxrisi: "0001", desckrat: "Category 1", isforos: true, isasf: false, isautoforos: false },
        { kodkrat: "02", kodxrisi: "0001", desckrat: "Category 2", isforos: false, isasf: true, isautoforos: false },
      ],
      rowcount: 2,
      columns: ["kodkrat", "kodxrisi", "desckrat", "isforos", "isasf", "isautoforos"],
    },
    misth_ypal: {
      rows: [
        { kodypal: "001", kodxrisi: "0001", surname: "Smith", name: "John", fathername: "Bob", mitroo: "A1", klimakio: "1", klados: "01", bathmos: "1", descidikot: "Engineer" },
      ],
      rowcount: 1,
      columns: ["kodypal", "kodxrisi", "surname", "name", "fathername", "mitroo", "klimakio", "klados", "bathmos", "descidikot"],
    },
    misth_zpepidom: {
      rows: [
        { kodepidom: "01", kodxrisi: "0001", descepidom: "Allowance 1", hasforo: true, isasf: false, autoforos: false, hasasf: false },
      ],
      rowcount: 1,
      columns: ["kodepidom", "kodxrisi", "descepidom", "hasforo", "isasf", "autoforos", "hasasf"],
    },
    misth_final: {
      rows: [
        { kodfinal: "001", kodxrisi: "0001", descfinal: "Final 1", datefinal: "2024-01-01", title: "Test", kodkat: "01", desckat: "Cat 1", kodperiod: "01", descperiod: "Jan", aa: 1 },
      ],
      rowcount: 1,
      columns: ["kodfinal", "kodxrisi", "descfinal", "datefinal", "title", "kodkat", "desckat", "kodperiod", "descperiod", "aa"],
    },
    misth_zpperiod: {
      rows: [
        { kodperiod: "01", kodxrisi: "0001", descperiod: "January", orderno: 1 },
        { kodperiod: "02", kodxrisi: "0001", descperiod: "February", orderno: 2 },
      ],
      rowcount: 2,
      columns: ["kodperiod", "kodxrisi", "descperiod", "orderno"],
    },
    afxtranslate: {
      rows: [
        { id: 655, uk: "Copyright" },
        { id: 529, uk: "Period" },
      ],
      rowcount: 2,
      columns: ["id", "uk"],
    },
  });
}
