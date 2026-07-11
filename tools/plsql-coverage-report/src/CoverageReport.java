import org.antlr.v4.runtime.*;
import org.antlr.v4.runtime.misc.IntervalSet;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Plan 162 Phase 0b -- redacted PL/SQL grammar coverage report (Java target).
 *
 * Standalone, offline, single-file-tree-in / aggregate-report-out. Walks a
 * directory of Oracle PL/SQL source files, attempts to parse each one with
 * the ANTLR4 grammars-v4/sql/plsql grammar (Java target, bundled into this
 * same jar), and prints a SHORT AGGREGATE REPORT to stdout.
 *
 * Rewritten from the original Python-target tool (2026-07-11): measured
 * ~15x faster on identical real-world files (see doc/plan/162-plsql-python-
 * frontend.md Status section), which matters directly here -- feedback
 * turnaround on a 763-file real corpus.
 *
 * PRIVACY CONTRACT (do not modify without re-reading doc/plan/162-plsql-
 * python-frontend.md's "Corpus access constraint" section first):
 *
 *   - This program NEVER prints, logs, or writes source text, identifiers,
 *     table/column names, or file paths from the scanned corpus.
 *   - Failure categories are keyed by structural info only: the innermost
 *     ANTLR parser rule name, and the *type* (symbolic token name, e.g.
 *     IDENTIFIER, EQUALS_OP) of the offending/expected tokens -- never
 *     their text.
 *   - Unit-kind counts (PACKAGE/PROCEDURE/FUNCTION/TRIGGER/...) are keyword
 *     occurrence COUNTS only, never the matched object name.
 *   - The only output is the printed report. Nothing is written to disk,
 *     nothing is transmitted over a network -- this program makes no
 *     network calls at all.
 *
 * Usage (no build step needed -- this jar is self-contained):
 *
 *     java -jar plsql-coverage-report.jar /path/to/plsql/corpus
 *
 * Requires only a JRE 8+ (built and verified against JDK 8 class-file
 * compatibility -- see README "JDK 8 compatibility").
 */
public class CoverageReport {

    static final Set<String> DEFAULT_EXTENSIONS = new HashSet<String>(Arrays.asList(
            ".sql", ".pks", ".pkb", ".pkg", ".trg", ".prc", ".fnc", ".pls", ".plb"));

    // Keyword-occurrence scan only -- deliberately does not capture the
    // object-name group, so no identifier is ever extracted from matched text.
    static final LinkedHashMap<String, Pattern> UNIT_KIND_PATTERNS = new LinkedHashMap<String, Pattern>();
    static {
        UNIT_KIND_PATTERNS.put("PACKAGE BODY", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?PACKAGE\\s+BODY\\b", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("PACKAGE", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?PACKAGE\\b(?!\\s+BODY)", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("PROCEDURE", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?PROCEDURE\\b", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("FUNCTION", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?FUNCTION\\b", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("TRIGGER", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?TRIGGER\\b", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("TYPE BODY", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?TYPE\\s+BODY\\b", Pattern.CASE_INSENSITIVE));
        UNIT_KIND_PATTERNS.put("TYPE", Pattern.compile("\\bCREATE\\s+(OR\\s+REPLACE\\s+)?TYPE\\b(?!\\s+BODY)", Pattern.CASE_INSENSITIVE));
    }

    static final Pattern IDENT_CHAR = Pattern.compile("[A-Za-z0-9_$#]");

    // ---- CLI options ----
    static class Options {
        File corpusDir;
        Set<String> exts = DEFAULT_EXTENSIONS;
        int timeoutSec = 60;
        int topN = 15;
        int dewrapWidth = 80;
        int dewrapTolerance = 0;
        boolean noDewrap = false;
    }

    /** Rejoins lines hard-wrapped mid-token at a fixed column width.
     *
     * Some Oracle DDL export pipelines hard-wrap every physical line at a
     * fixed column count (observed: exactly 80) with a bare newline and
     * nothing else inserted -- including mid-identifier, e.g. a line ending
     * "...PROCEDURE_NA" immediately followed by a line starting
     * "ME IS...". That is not a real line break and left alone it poisons
     * the parse with spurious errors unrelated to actual grammar coverage.
     *
     * Detection is deliberately narrow, not a general reflow: a boundary
     * between original line i and i+1 is treated as a wrap artifact only
     * when BOTH hold: (1) line i's length is within `tolerance` of `width`,
     * and (2) the last char of line i and the first char of line i+1 are
     * both PL/SQL identifier-continuation characters ([A-Za-z0-9_$#]).
     * Normal PL/SQL formatting never places a raw newline inside an
     * identifier/keyword; real line breaks fall at whitespace or
     * punctuation. That makes (2) alone a strong, low-false-positive
     * signal; (1) is a corroborating gate matching the reported wrap width.
     *
     * Rejoining is pure concatenation (no separator inserted), matching the
     * reported wrap format (bare newline, nothing else). Handles chains of
     * 3+ wrapped fragments by re-checking each pairwise *original* line
     * boundary, not the length of the growing merged buffer.
     */
    static class DewrapResult {
        String text;
        int joins;
    }

    static DewrapResult dewrapHardWrappedLines(String text, int width, int tolerance) {
        String[] orig = text.split("\n", -1);
        int n = orig.length;
        StringBuilder out = new StringBuilder();
        int joins = 0;
        int i = 0;
        while (i < n) {
            StringBuilder buf = new StringBuilder(orig[i]);
            while (i + 1 < n
                    && orig[i].length() > 0
                    && orig[i + 1].length() > 0
                    && Math.abs(orig[i].length() - width) <= tolerance
                    && IDENT_CHAR.matcher(String.valueOf(orig[i].charAt(orig[i].length() - 1))).matches()
                    && IDENT_CHAR.matcher(String.valueOf(orig[i + 1].charAt(0))).matches()) {
                buf.append(orig[i + 1]);
                i++;
                joins++;
            }
            if (out.length() > 0) out.append("\n");
            out.append(buf);
            i++;
        }
        DewrapResult r = new DewrapResult();
        r.text = out.toString();
        r.joins = joins;
        return r;
    }

    /** Captures structural error shape only -- never offending-token text. */
    static class ErrorEntry {
        String innermostRule;
        String offendingType;
        List<String> expectedTypes;
        int line;
    }

    static class RedactedErrorListener extends BaseErrorListener {
        List<ErrorEntry> errors = new ArrayList<ErrorEntry>();

        @Override
        public void syntaxError(Recognizer<?, ?> recognizer, Object offendingSymbol, int line,
                                 int charPositionInLine, String msg, RecognitionException e) {
            ErrorEntry entry = new ErrorEntry();
            entry.line = line;

            String innermost = null;
            if (recognizer instanceof Parser) {
                Parser parser = (Parser) recognizer;
                RuleContext ctx = parser.getContext();
                if (ctx != null) {
                    innermost = parser.getRuleNames()[ctx.getRuleIndex()];
                }
            }
            entry.innermostRule = innermost;

            String offendingType = null;
            if (offendingSymbol instanceof Token) {
                Token t = (Token) offendingSymbol;
                offendingType = symbolicName(recognizer, t.getType());
            }
            entry.offendingType = offendingType;

            List<String> expected = new ArrayList<String>();
            if (e != null) {
                // getExpectedTokens() assumes a parser rule-invocation
                // context; on a lexer-level error (e.g. a stray '$' the
                // lexer can't match to any token) the ATN state it's
                // computed against has no such context and this throws
                // IllegalArgumentException("Invalid state number") --
                // matching the Python tool's own defensive try/except
                // around the identical call, this is expected-and-skipped,
                // not a real crash.
                try {
                    IntervalSet expectedTokens = e.getExpectedTokens();
                    if (expectedTokens != null) {
                        List<Integer> types = expectedTokens.toList();
                        for (int i = 0; i < types.size() && i < 8; i++) {
                            expected.add(symbolicName(recognizer, types.get(i)));
                        }
                    }
                } catch (Exception ignore) {
                    // no expected-token info available for this error shape
                }
            }
            Collections.sort(expected);
            entry.expectedTypes = expected;

            errors.add(entry);
        }

        private String symbolicName(Recognizer<?, ?> recognizer, int tokenType) {
            try {
                Vocabulary vocab = recognizer.getVocabulary();
                String name = vocab.getSymbolicName(tokenType);
                return name != null ? name : ("<type " + tokenType + ">");
            } catch (Exception ex) {
                return "<type " + tokenType + ">";
            }
        }
    }

    enum Status { PASS, FAIL, TIMEOUT, EMPTY, READ_ERROR, CRASH }

    static class FileResult {
        Status status;
        int nErrors;
        ErrorEntry firstError;
    }

    static List<ErrorEntry> parseFile(final String text) throws Exception {
        CharStream input = CharStreams.fromString(text);
        PlSqlLexer lexer = new PlSqlLexer(input);
        lexer.removeErrorListeners();
        RedactedErrorListener lexErrs = new RedactedErrorListener();
        lexer.addErrorListener(lexErrs);

        CommonTokenStream tokens = new CommonTokenStream(lexer);
        PlSqlParser parser = new PlSqlParser(tokens);
        parser.removeErrorListeners();
        RedactedErrorListener parseErrs = new RedactedErrorListener();
        parser.addErrorListener(parseErrs);
        // Deliberately default (full LL) prediction mode, NOT SLL: SLL is an
        // approximation that can mis-parse or spuriously fail on genuinely
        // context-dependent constructs (observed: collection_method_call
        // false-failures jumped 1 -> 35 files under SLL on this same corpus
        // during this tool's own development -- see git history/plan notes).
        // For a coverage/correctness report, accuracy matters more than the
        // throughput SLL buys; Java's target-language speed advantage over
        // the Python tool holds independently of prediction-mode choice.

        parser.sql_script();

        List<ErrorEntry> all = new ArrayList<ErrorEntry>();
        all.addAll(lexErrs.errors);
        all.addAll(parseErrs.errors);
        return all;
    }

    static List<File> collectFiles(File root, final Set<String> exts) {
        final List<File> out = new ArrayList<File>();
        walk(root, exts, out);
        Collections.sort(out);
        return out;
    }

    static void walk(File dir, Set<String> exts, List<File> out) {
        File[] children = dir.listFiles();
        if (children == null) return;
        for (File c : children) {
            if (c.isDirectory()) {
                walk(c, exts, out);
            } else {
                String name = c.getName().toLowerCase(Locale.ROOT);
                int dot = name.lastIndexOf('.');
                String ext = dot >= 0 ? name.substring(dot) : "";
                if (exts.contains(ext)) out.add(c);
            }
        }
    }

    static Options parseArgs(String[] args) {
        Options o = new Options();
        List<String> positional = new ArrayList<String>();
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if (a.equals("--timeout")) {
                o.timeoutSec = Integer.parseInt(args[++i]);
            } else if (a.equals("--top-n")) {
                o.topN = Integer.parseInt(args[++i]);
            } else if (a.equals("--dewrap-width")) {
                o.dewrapWidth = Integer.parseInt(args[++i]);
            } else if (a.equals("--dewrap-tolerance")) {
                o.dewrapTolerance = Integer.parseInt(args[++i]);
            } else if (a.equals("--no-dewrap")) {
                o.noDewrap = true;
            } else if (a.equals("--ext")) {
                Set<String> exts = new HashSet<String>();
                while (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                    String e = args[++i].toLowerCase(Locale.ROOT);
                    exts.add(e.startsWith(".") ? e : "." + e);
                }
                o.exts = exts;
            } else if (a.equals("-h") || a.equals("--help")) {
                printHelp();
                System.exit(0);
            } else {
                positional.add(a);
            }
        }
        if (positional.isEmpty()) {
            System.err.println("error: corpus directory argument is required");
            printHelp();
            System.exit(1);
        }
        o.corpusDir = new File(positional.get(0));
        return o;
    }

    static void printHelp() {
        System.out.println("Usage: java -jar plsql-coverage-report.jar <corpus_dir> [options]");
        System.out.println("  --ext EXT [EXT ...]        File extensions to scan (default: " + DEFAULT_EXTENSIONS + ")");
        System.out.println("  --timeout SECONDS          Per-file parse timeout (default: 60)");
        System.out.println("  --top-n N                  Rows in the failure-category table (default: 15)");
        System.out.println("  --dewrap-width N           Column width for the hard-wrap rejoin heuristic (default: 80)");
        System.out.println("  --dewrap-tolerance N       +/- tolerance in chars when matching --dewrap-width (default: 0)");
        System.out.println("  --no-dewrap                Disable the hard-wrap rejoin heuristic entirely");
    }

    public static void main(String[] args) throws Exception {
        Options opt = parseArgs(args);

        if (!opt.corpusDir.isDirectory()) {
            System.err.println("error: " + opt.corpusDir + " is not a directory");
            System.exit(1);
        }

        List<File> files = collectFiles(opt.corpusDir, opt.exts);
        int totalFiles = files.size();
        long totalLines = 0;
        LinkedHashMap<String, Integer> unitKindCounts = new LinkedHashMap<String, Integer>();
        for (String k : UNIT_KIND_PATTERNS.keySet()) unitKindCounts.put(k, 0);

        Map<Status, Integer> statusCounts = new EnumMap<Status, Integer>(Status.class);
        for (Status s : Status.values()) statusCounts.put(s, 0);

        Map<String, Integer> errorCountBuckets = new LinkedHashMap<String, Integer>();
        errorCountBuckets.put("1", 0);
        errorCountBuckets.put("2-5", 0);
        errorCountBuckets.put("6+", 0);

        // key: "rule|found|expected1,expected2,..."
        Map<String, Integer> failCategoryCounts = new LinkedHashMap<String, Integer>();
        Map<String, String> failCategoryDisplay = new LinkedHashMap<String, String>();
        // Position of the first error within its file, bucketed as a
        // fraction of file length -- "early" (<10%) is the strongest signal
        // a category is a genuine, isolated coverage gap (the very first
        // construct in the file is what broke); "late" (>50%) is a strong
        // signal it's a cascading/secondary symptom of something upstream
        // in the same file (ANTLR's own error-recovery resync, or simply a
        // different earlier construct this report attributes to a
        // different category since only the first error per FILE is
        // counted, not first error per problem). Matches this project's
        // "primary failures hide secondary failures" principle -- without
        // this, a downstream artifact is indistinguishable from a real gap.
        Map<String, int[]> failCategoryPosition = new LinkedHashMap<String, int[]>(); // [early, mid, late]

        long totalDewrapJoins = 0;
        int filesDewrapped = 0;

        // Large explicit stack size: ANTLR's adaptive-LL simulation can
        // recurse deeply on pathological/deeply-nested real expressions,
        // and the JVM's default per-thread stack (~512KB-1MB) is smaller
        // than what the equivalent Python run tolerated via its raised
        // sys.setrecursionlimit(10000) -- without this, a handful of real
        // files throw StackOverflowError (an Error, not an Exception, but
        // still surfaces via Future.get()'s ExecutionException and gets
        // counted as CRASH below; this just avoids the false crash).
        final long WORKER_STACK_BYTES = 256L * 1024 * 1024;
        ExecutorService executor = Executors.newSingleThreadExecutor(new ThreadFactory() {
            public Thread newThread(Runnable r) {
                Thread t = new Thread(null, r, "parse-worker", WORKER_STACK_BYTES);
                t.setDaemon(true);
                return t;
            }
        });

        long tStart = System.nanoTime();

        for (int i = 0; i < files.size(); i++) {
            File path = files.get(i);
            System.err.print("\r  scanning " + (i + 1) + "/" + totalFiles + "...");
            System.err.flush();

            String text;
            try {
                byte[] bytes = Files.readAllBytes(path.toPath());
                text = new String(bytes, StandardCharsets.UTF_8);
            } catch (IOException e) {
                statusCounts.put(Status.READ_ERROR, statusCounts.get(Status.READ_ERROR) + 1);
                continue;
            }

            int nLines = countLines(text);
            totalLines += nLines;

            for (Map.Entry<String, Pattern> e : UNIT_KIND_PATTERNS.entrySet()) {
                Matcher m = e.getValue().matcher(text);
                int count = 0;
                while (m.find()) count++;
                unitKindCounts.put(e.getKey(), unitKindCounts.get(e.getKey()) + count);
            }

            if (!opt.noDewrap) {
                DewrapResult dr = dewrapHardWrappedLines(text, opt.dewrapWidth, opt.dewrapTolerance);
                text = dr.text;
                // Recompute for the position-bucket denominator below:
                // ANTLR's error line numbers are measured against this
                // POST-dewrap text, which has fewer lines than nLines
                // (originally captured pre-dewrap) whenever any rejoining
                // happened -- using the larger pre-dewrap count here would
                // systematically understate the fraction for exactly the
                // heavily-wrapped files this bucketing exists to analyze.
                nLines = countLines(text);
                if (dr.joins > 0) {
                    totalDewrapJoins += dr.joins;
                    filesDewrapped++;
                }
            }

            if (text.trim().isEmpty()) {
                statusCounts.put(Status.EMPTY, statusCounts.get(Status.EMPTY) + 1);
                continue;
            }

            final String parseText = text;
            Future<List<ErrorEntry>> future = executor.submit(new Callable<List<ErrorEntry>>() {
                public List<ErrorEntry> call() throws Exception {
                    return parseFile(parseText);
                }
            });

            List<ErrorEntry> errors;
            try {
                errors = future.get(opt.timeoutSec, TimeUnit.SECONDS);
            } catch (TimeoutException te) {
                future.cancel(true);
                statusCounts.put(Status.TIMEOUT, statusCounts.get(Status.TIMEOUT) + 1);
                continue;
            } catch (Exception ex) {
                statusCounts.put(Status.CRASH, statusCounts.get(Status.CRASH) + 1);
                continue;
            }

            if (errors.isEmpty()) {
                statusCounts.put(Status.PASS, statusCounts.get(Status.PASS) + 1);
            } else {
                statusCounts.put(Status.FAIL, statusCounts.get(Status.FAIL) + 1);
                int nErr = errors.size();
                String bucket = nErr == 1 ? "1" : (nErr <= 5 ? "2-5" : "6+");
                errorCountBuckets.put(bucket, errorCountBuckets.get(bucket) + 1);

                ErrorEntry first = errors.get(0);
                String expectedStr = join(first.expectedTypes, ",");
                String key = first.innermostRule + "|" + first.offendingType + "|" + expectedStr;
                Integer cur = failCategoryCounts.get(key);
                failCategoryCounts.put(key, cur == null ? 1 : cur + 1);
                failCategoryDisplay.put(key, "rule=" + first.innermostRule + "  found=" + first.offendingType
                        + "  expected=[" + expectedStr + "]");

                int[] posCounts = failCategoryPosition.get(key);
                if (posCounts == null) {
                    posCounts = new int[3];
                    failCategoryPosition.put(key, posCounts);
                }
                double frac = nLines > 0 ? first.line / (double) nLines : 0;
                if (frac < 0.10) posCounts[0]++;
                else if (frac <= 0.50) posCounts[1]++;
                else posCounts[2]++;
            }
        }

        executor.shutdownNow();
        double elapsed = (System.nanoTime() - tStart) / 1e9;
        System.err.println();

        // ---- Aggregate report (safe to hand-type back) ----
        System.out.println(repeat("=", 70));
        System.out.println("Plan 162 Phase 0b - PL/SQL grammar coverage report (redacted, Java)");
        System.out.println(repeat("=", 70));
        System.out.printf("%nScan wall time: %.1fs%n", elapsed);
        System.out.println("Total files scanned: " + totalFiles);
        System.out.println("Total lines: " + totalLines);
        if (!opt.noDewrap) {
            System.out.println("Hard-wrap rejoins performed: " + totalDewrapJoins + "  (in " + filesDewrapped + " of " + totalFiles + " files)");
        }

        System.out.println("\nUnit-kind occurrence counts (keyword scan, count only):");
        List<Map.Entry<String, Integer>> unitEntries = new ArrayList<Map.Entry<String, Integer>>(unitKindCounts.entrySet());
        Collections.sort(unitEntries, new Comparator<Map.Entry<String, Integer>>() {
            public int compare(Map.Entry<String, Integer> a, Map.Entry<String, Integer> b) {
                return b.getValue() - a.getValue();
            }
        });
        for (Map.Entry<String, Integer> e : unitEntries) {
            if (e.getValue() > 0) System.out.printf("  %-14s %d%n", e.getKey(), e.getValue());
        }

        System.out.println("\nParse outcome counts:");
        List<Map.Entry<Status, Integer>> statusEntries = new ArrayList<Map.Entry<Status, Integer>>(statusCounts.entrySet());
        Collections.sort(statusEntries, new Comparator<Map.Entry<Status, Integer>>() {
            public int compare(Map.Entry<Status, Integer> a, Map.Entry<Status, Integer> b) {
                return b.getValue() - a.getValue();
            }
        });
        for (Map.Entry<Status, Integer> e : statusEntries) {
            if (e.getValue() > 0) {
                double pct = totalFiles > 0 ? 100.0 * e.getValue() / totalFiles : 0;
                System.out.printf("  %-16s %5d  (%.1f%%)%n", e.getKey().toString().toLowerCase(Locale.ROOT), e.getValue(), pct);
            }
        }

        int nFail = statusCounts.get(Status.FAIL);
        if (nFail > 0) {
            System.out.printf("%nFailing-file error-count distribution (isolability proxy, n=%d):%n", nFail);
            for (String bucket : new String[]{"1", "2-5", "6+"}) {
                System.out.printf("  %-6s errors: %d%n", bucket, errorCountBuckets.get(bucket));
            }
        }

        System.out.printf("%nTop %d failure categories (innermost_rule, offending_token_type, expected_token_types):%n", opt.topN);
        System.out.println("  (position = where in its file the error falls: early <10%, mid 10-50%, late >50% --");
        System.out.println("   early is the strongest signal of a genuine isolated gap; late suggests a cascading/");
        System.out.println("   secondary symptom of something earlier in the same file, not this construct itself)");
        List<Map.Entry<String, Integer>> failEntries = new ArrayList<Map.Entry<String, Integer>>(failCategoryCounts.entrySet());
        Collections.sort(failEntries, new Comparator<Map.Entry<String, Integer>>() {
            public int compare(Map.Entry<String, Integer> a, Map.Entry<String, Integer> b) {
                return b.getValue() - a.getValue();
            }
        });
        int shown = 0;
        for (Map.Entry<String, Integer> e : failEntries) {
            if (shown++ >= opt.topN) break;
            int[] pos = failCategoryPosition.get(e.getKey());
            String posStr = pos == null ? "" : String.format("  [early=%d mid=%d late=%d]", pos[0], pos[1], pos[2]);
            System.out.printf("  %4d  %s%s%n", e.getValue(), failCategoryDisplay.get(e.getKey()), posStr);
        }

        System.out.println("\n" + repeat("=", 70));
        System.out.println("End of report. Nothing else was written or transmitted.");
        System.out.println(repeat("=", 70));

        System.exit(0);
    }

    static int countLines(String text) {
        int n = 1;
        for (int i = 0; i < text.length(); i++) if (text.charAt(i) == '\n') n++;
        return n;
    }

    static String join(List<String> items, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(sep);
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    static String repeat(String s, int n) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) sb.append(s);
        return sb.toString();
    }
}
