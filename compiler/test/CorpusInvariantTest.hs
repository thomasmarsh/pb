module CorpusInvariantTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)
import PB.Pipeline.FileWalk   (walkDwFiles, walkPsFiles)
import PB.Pipeline.Emit       (parsePowerScriptFile)
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText)
import PB.AST.SourceFile
  ( SrFile (..), FunctionBlock (..), SubroutineBlock (..)
  , EventBlock (..), OnBlock (..), TypeBlock (..)
  )
import PB.AST.BodyStmt
  ( BodyStmt (..), IfStmt (..), ForStmt (..), DoStmt (..)
  , ChooseStmt (..), TryStmt (..), ElseIf (..), CaseClause (..), CatchClause (..)
  )
import PB.AST.Located (Located (..))
import RepoRoot (repoRoot)

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict   as Map
import qualified Data.Text as T
import System.FilePath  ((</>))

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

-- ---------------------------------------------------------------------------
-- JSON helpers

lk :: Text -> Value -> Value
lk k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
lk _ _          = Null

tagOf :: Value -> Text
tagOf v = case lk "tag" v of { String t -> t; _ -> "" }

segsOf :: Value -> [Value]
segsOf v = case lk "segments" v of { Array vs -> toList vs; _ -> [] }

-- Every single-positional-argument constructor (one field, no record syntax)
-- wraps its payload under a top-level "contents" key -- see
-- compiler/AGENTS.md's "JSON body-statement encoding" note.
contentsOf :: Value -> Value
contentsOf = lk "contents"

-- First element of a "contents" array -- for two-*unnamed*-positional-arg
-- constructors (e.g. 'BsAssign'), which Aeson serialises as
-- @{"tag":...,"contents":[fst,snd]}@, not a record with named fields.
firstContentsOf :: Value -> Value
firstContentsOf v = case contentsOf v of
    Array vs -> case toList vs of { (x : _) -> x; [] -> Null }
    _        -> Null

isEmptyExRaw :: Value -> Bool
isEmptyExRaw v = tagOf v == "ExRaw" && case contentsOf v of
    Array ts -> null (toList ts)
    _        -> False

-- ---------------------------------------------------------------------------
-- Tree walker

-- Walk every node in a JSON tree depth-first, accumulating violation strings.
walkTree :: (Value -> [Text]) -> Value -> [Text]
walkTree check val = check val ++ case val of
    Object m  -> concatMap (walkTree check) (KM.elems m)
    Array  vs -> concatMap (walkTree check) (toList vs)
    _         -> []

-- ---------------------------------------------------------------------------
-- Corpus loader

-- Run the parser on one file; return Nothing on Left (parse error).
loadFile :: FilePath -> IO (Maybe (FilePath, Value))
loadFile path = do
    src <- readFile path
    pure $ case runFile path src of
        Left  _  -> Nothing
        Right v  -> Just (path, v)

-- The two corpus directories, resolved against the repo root -- Cabal runs
-- the built test binary with cwd = the package directory (@compiler/@), but
-- these directories live at the repo root, one level up.
corpusDirs :: IO [FilePath]
corpusDirs = do
    root <- repoRoot
    pure [ root </> "example" </> "PowerBuilder-Example-extract"
         , root </> "example" </> "openpay-0.1.1b-extract"
         ]

-- Load all successfully-parsed files from both corpora.
loadCorpus :: IO [(FilePath, Value)]
loadCorpus = do
    dirs  <- corpusDirs
    paths <- fmap concat $ mapM walkPsFiles dirs
    results <- mapM loadFile paths
    pure (concatMap maybeToList results)

-- Load all successfully-parsed .srd files.
loadDwCorpus :: IO [(FilePath, Value)]
loadDwCorpus = do
    dirs  <- corpusDirs
    paths <- fmap concat $ mapM walkDwFiles dirs
    results <- mapM loadFile paths
    pure (concatMap maybeToList results)

-- ---------------------------------------------------------------------------
-- Invariant runner

type NodeCheck = Value -> [Text]

-- Run a node-level check across all corpus trees; collect (file, msg) pairs.
runNodeCheck :: NodeCheck -> IO [(FilePath, Text)]
runNodeCheck check = do
    pairs <- loadCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- walkTree check v]

-- Run a file-level check (operates on the top-level Value per file).
runFileCheck :: (FilePath -> Value -> [Text]) -> IO [(FilePath, Text)]
runFileCheck check = do
    pairs <- loadCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- check f v]

runDwNodeCheck :: NodeCheck -> IO [(FilePath, Text)]
runDwNodeCheck check = do
    pairs <- loadDwCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- walkTree check v]

runDwFileCheck :: (FilePath -> Value -> [Text]) -> IO [(FilePath, Text)]
runDwFileCheck check = do
    pairs <- loadDwCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- check f v]

assertNoViolations :: String -> [(FilePath, Text)] -> IO ()
assertNoViolations name viols =
    assertBool msg (null viols)
  where
    shown = concatMap (\(f, m) -> "  " <> f <> ": " <> T.unpack m <> "\n") (take 10 viols)
    total = length viols
    msg   = "Invariant '" <> name <> "' — " <> show total
              <> " violation(s):\n" <> shown

-- ---------------------------------------------------------------------------
-- Node checks

chkLvalueSegs :: NodeCheck
chkLvalueSegs v
    | tagOf v == "ExLvalue" && null (segsOf (contentsOf v)) = ["lvalue with empty segments"]
    | otherwise                                              = []

chkCallExprCallee :: NodeCheck
chkCallExprCallee v
    | tagOf v == "ExCall"
    , null (segsOf (lk "callee" v)) = ["call_expr with empty callee segments"]
    | otherwise                      = []

-- 'BsAssign' has two *unnamed* positional args (@Lvalue Expr@), so Aeson
-- serialises it as @{"tag":"BsAssign","contents":[lhsJson,rhsJson]}@ -- an
-- array, not a record with an "lhs" key.
chkAssignLhs :: NodeCheck
chkAssignLhs v
    | tagOf v == "BsAssign"
    , null (segsOf (firstContentsOf v)) = ["assign with empty lhs segments"]
    | otherwise                          = []

-- 'ExHostVar' wraps a bare 'Lvalue' (single positional arg), so "contents"
-- *is* the lvalue object directly -- no separate "lvalue" key.
chkHostVarSegs :: NodeCheck
chkHostVarSegs v
    | tagOf v == "ExHostVar"
    , null (segsOf (contentsOf v)) = ["host_var with empty lvalue segments"]
    | otherwise                     = []

chkForVarSegs :: NodeCheck
chkForVarSegs v
    | tagOf v == "BsFor"
    , null (segsOf (lk "var" (contentsOf v))) = ["for with empty var segments"]
    | otherwise                                = []

chkNoEmptyExRaw :: NodeCheck
chkNoEmptyExRaw v
    | isEmptyExRaw v = ["ExRaw node with zero tokens"]
    | otherwise      = []

chkBinopOperands :: NodeCheck
chkBinopOperands v
    | tagOf v == "ExBinOp"
    = [msg | (field, side) <- [("lhs", lk "lhs" v), ("rhs", lk "rhs" v)]
            , isEmptyExRaw side
            , let msg = "binop " <> field <> " is empty ExRaw"]
    | otherwise = []

chkIfCond :: NodeCheck
chkIfCond v
    | tagOf v == "BsIf" && isEmptyExRaw (lk "cond" (contentsOf v)) = ["if cond is empty ExRaw"]
    | otherwise                                                     = []

chkForBounds :: NodeCheck
chkForBounds v
    | tagOf v == "BsFor"
    = [msg | (field, side) <- [("from", lk "from" (contentsOf v)), ("to", lk "to" (contentsOf v))]
            , isEmptyExRaw side
            , let msg = "for " <> field <> " is empty ExRaw"]
    | otherwise = []

chkChooseExpr :: NodeCheck
chkChooseExpr v
    | tagOf v == "BsChoose" && isEmptyExRaw (lk "expr" (contentsOf v)) = ["choose expr is empty ExRaw"]
    | otherwise                                                         = []

-- ---------------------------------------------------------------------------
-- File-level checks

chkFnNames :: FilePath -> Value -> [Text]
chkFnNames _ v = case lk "functions" v of
    Array fs -> [msg | f <- toList fs
                     , let name = case lk "name" (lk "sig" f) of
                                    String t -> t; _ -> ""
                     , T.null name
                     , let msg = "function with empty sig.name"]
    _        -> []

chkSubNames :: FilePath -> Value -> [Text]
chkSubNames _ v = case lk "subroutines" v of
    Array ss -> [msg | s <- toList ss
                     , let name = case lk "name" (lk "sig" s) of
                                    String t -> t; _ -> ""
                     , T.null name
                     , let msg = "subroutine with empty sig.name"]
    _        -> []

-- ---------------------------------------------------------------------------
-- PS meta checks

-- Collects all callable blocks from a PS file value.
psCallableBlocks :: Value -> [Value]
psCallableBlocks v
    | lk "kind" v /= String "powerscript" = []
    | otherwise = concatMap (\k -> case lk k v of { Array bs -> toList bs; _ -> [] })
                            ["functions", "events", "onBlocks", "subroutines"]

chkPsMetaFile :: FilePath -> Value -> [Text]
chkPsMetaFile _ v =
    [ "callable block missing meta.file"
    | b <- psCallableBlocks v
    , case lk "file" (lk "meta" b) of { String _ -> False; _ -> True }
    ]

chkPsMetaObject :: FilePath -> Value -> [Text]
chkPsMetaObject _ v =
    [ "callable block missing meta.object"
    | b <- psCallableBlocks v
    , case lk "object" (lk "meta" b) of { String _ -> False; _ -> True }
    ]

chkPsMetaStartLine :: FilePath -> Value -> [Text]
chkPsMetaStartLine _ v =
    [ "callable block meta.startLine not > 0"
    | b <- psCallableBlocks v
    , case lk "startLine" (lk "meta" b) of { Number n -> n <= 0; _ -> True }
    ]

chkPsMetaEndLine :: FilePath -> Value -> [Text]
chkPsMetaEndLine _ v =
    [ "callable block meta.endLine < meta.startLine"
    | b <- psCallableBlocks v
    , let meta = lk "meta" b
    , case (lk "startLine" meta, lk "endLine" meta) of
        (Number sl, Number el) -> el < sl
        _                      -> True
    ]

-- ---------------------------------------------------------------------------
-- DW-specific node and file checks

chkDwArgConsistency :: FilePath -> Value -> [Text]
chkDwArgConsistency _ v
    | lk "kind" v /= String "datawindow" = []
    | otherwise =
        let tableV = lk "table" v
            retrieve = lk "retrieve" tableV
        in case lk "version" retrieve of
            Null -> []  -- DwRetrieveRaw or no table: skip
            _    ->
                let dtCount = case lk "arguments" tableV  of { Array xs -> length (toList xs); _ -> 0 }
                    drCount = case lk "arguments" retrieve of { Array xs -> length (toList xs); _ -> 0 }
                in if dtCount == drCount then []
                   else [ "dtArguments count " <> T.pack (show dtCount)
                        <> " != drArguments count " <> T.pack (show drCount) ]

chkDwNotStub :: FilePath -> Value -> [Text]
chkDwNotStub _ v
    | lk "kind"   v == String "datawindow"
    , lk "status" v == String "unimplemented" = ["DW file is stub"]
    | otherwise = []

chkDwBandsNonEmpty :: FilePath -> Value -> [Text]
chkDwBandsNonEmpty _ v
    | lk "kind" v /= String "datawindow" = []
    | otherwise = case lk "bands" v of
        Array bs | not (null (toList bs)) -> []
        _                                 -> ["DW file has no bands"]

-- Fires on DwControl nodes with type="column" that are missing an id.
-- "column" is a DW control type; PB data types (long/char/date/etc.) are
-- never literally "column", so this safely identifies DwControl column nodes.
chkDwColumnControlHasId :: NodeCheck
chkDwColumnControlHasId v
    | lk "type" v == String "column"
    , lk "id"   v == Null = ["column control has null id"]
    | otherwise = []

-- Fires on DwColumn nodes (identified by presence of "db_name" key) that
-- have a null or empty "name".  Uses KM.member to distinguish "absent" from
-- "present but null" when checking for the discriminating key.
chkDwTableColumnNameNonEmpty :: NodeCheck
chkDwTableColumnNameNonEmpty (Object m)
    | KM.member (Key.fromText "db_name") m =
        case KM.lookup (Key.fromText "name") m of
          Just (String t) | T.null t -> ["table column with empty name"]
          Just (String _)            -> []
          _                          -> ["table column with null name"]
chkDwTableColumnNameNonEmpty _ = []

-- ---------------------------------------------------------------------------
-- Comma-declarator truncation check (Plan 194)
--
-- Coarse corpus-level second signal against silent truncation of a
-- comma-separated declarator list (the bug class Plan 193 found in
-- 'PB.Grammar.Body.classifyBodyStmt'/'PB.Grammar.File.buildVarDecls' --
-- both shipped silently since a truncated statement still parses
-- successfully, so the corpus error-count gate can't see it). Compares an
-- independent raw-text scan of every logical line against the real
-- typed parse, restricted to 'BsLocalVar' declarations (function/event/
-- subroutine/on-block/type-block bodies) -- 'PB.AST.SourceFile.VarDecl'
-- has no per-declaration source line ('buildVarDecls' flattens a comma
-- statement into a bare list with no 'Located' wrapper), so a symmetric
-- raw-vs-extracted comparison can't group its declarations by original
-- statement; that gap is covered instead by the exact per-statement
-- Hedgehog properties in FileTest.hs's "pVarDecl" group.
--
-- Both sides are restricted to lines/statements with at least one
-- top-level comma (i.e. 2+ names) -- a single-name declaration
-- contributes to neither side, keeping the check scoped to the
-- truncation bug's actual shape instead of needing every declarator
-- line to be raw-text-matchable.

-- | Every source file that parses, paired with its raw text (for the raw
-- side of the comparison) and its typed 'SrFile' (for the extracted side).
loadTypedCorpus :: IO [(FilePath, Text, SrFile)]
loadTypedCorpus = do
    dirs  <- corpusDirs
    paths <- fmap concat $ mapM walkPsFiles dirs
    results <- mapM loadTypedFile paths
    pure (concatMap maybeToList results)
  where
    loadTypedFile path = do
        src <- readFile path
        pure $ case parsePowerScriptFile src of
            Left _           -> Nothing
            Right (sf, _, _) -> Just (path, src, sf)

-- | Sum of 'declaredNamesInSegment' over every top-level (depth-0)
-- ';'-separated statement segment in the line -- PowerScript routinely
-- packs multiple statements onto one physical/logical line (e.g.
-- @event ue_x;call ancestor::ue_x;String ls_a, ls_b@), and checking only
-- the line's first two words would either miss a real declarator later
-- in the line or (worse) misattribute its comma to an unrelated header.
declaredNamesInLine :: Text -> Int
declaredNamesInLine raw =
    sum [n | seg <- splitTopLevelSemicolons (fst (T.breakOn "//" raw))
            , Just n <- [declaredNamesInSegment seg]]

-- | Depth-0 (bracket/paren-aware) comma count in the tail of a statement
-- segment after its first two bare-identifier tokens, if it has one.
-- 'Nothing' means "doesn't look like a multi-name declarator segment" --
-- deliberately conservative (see the module-level note above): the
-- two-bare-word-then-comma shape is what every PowerScript var-decl
-- segment shares and control-flow keywords never produce, with one
-- corpus-confirmed exception needing an explicit deny-list on word1:
-- "case NEW!, NEWMODIFIED!" -- PB enum-literal case values are
-- bare-word-shaped ('!' isn't an identifier char so word2 stops right
-- after "New"). Block comments are stripped upstream by
-- 'stripBlockComments' before this ever runs; not a second parser: a
-- comma inside a string literal is still not specially handled (a
-- documented, accepted false-positive source for this coarse signal).
declaredNamesInSegment :: Text -> Maybe Int
declaredNamesInSegment raw =
    let t             = T.stripStart raw
        (w1, rest1)   = T.span isIdentChar t
        rest1'        = skipBracePrecision (T.stripStart rest1)
        (w2, rest2)   = T.span isIdentChar (T.stripStart rest1')
    in if not (isBareIdent w1) || isNeverDeclKw w1 || not (isBareIdent w2)
       then Nothing
       else case countTopLevelCommas rest2 of
              0      -> Nothing
              commas -> Just (commas + 1)
  where
    isIdentStart c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    isIdentChar  c = isIdentStart c || (c >= '0' && c <= '9')
    isBareIdent w  = not (T.null w) && isIdentStart (T.head w)
    -- Keywords that start a statement shape a comma can legitimately
    -- follow without it ever being a declarator list (see the
    -- corpus-confirmed case in the docs above; the rest are precautionary
    -- -- all are reserved words, so excluding them can never reject a
    -- real type name).
    isNeverDeclKw w = T.toLower w `elem`
        [ "case", "event", "on", "call", "choose", "do", "for", "if"
        , "return", "while", "loop", "try", "catch", "throw"
        -- Embedded SQL leading keywords (grammar coverage for embedded SQL
        -- is "pending" per compiler/AGENTS.md's Corpus Coverage Checklist
        -- -- it stays 'BsRaw' text, and a multi-line SQL statement's own
        -- clause keywords land as word1/word2 of their own logical line
        -- just as often as a real declarator does, e.g. "FROM customer,
        -- orders" or "fetch lcur into :a, :b").
        , "select", "insert", "update", "delete", "from", "where"
        , "order", "group", "having", "values", "set", "into", "fetch"
        , "declare", "execute", "exec", "commit", "rollback", "grant"
        , "revoke", "join", "union"
        ]
    -- Skip a `{N}` precision qualifier directly after the type keyword
    -- (e.g. `decimal{2} lc_x, lc_y` -- 'PB.AST.Type.PtDecimalPrec's
    -- surface syntax), so word2 extraction lands on the real first name.
    skipBracePrecision s = case T.uncons s of
        Just ('{', rest) -> T.drop 1 (T.dropWhile (/= '}') rest)
        _                -> s

-- | Split on depth-0 (bracket/paren/brace/string-aware) ';' characters.
splitTopLevelSemicolons :: Text -> [Text]
splitTopLevelSemicolons = go (0 :: Int) False []
  where
    go _     _     acc t | T.null t = [T.concat (reverse acc)]
    go depth inStr acc t = case T.head t of
        '"'                             -> go depth (not inStr) (T.singleton '"' : acc) (T.tail t)
        c | inStr                       -> go depth inStr (T.singleton c : acc) (T.tail t)
        c | c `elem` ("([{" :: String)  -> go (depth + 1) inStr (T.singleton c : acc) (T.tail t)
        c | c `elem` (")]}" :: String)  -> go (max 0 (depth - 1)) inStr (T.singleton c : acc) (T.tail t)
        ';' | depth == 0                -> T.concat (reverse acc) : go depth inStr [] (T.tail t)
        c                               -> go depth inStr (T.singleton c : acc) (T.tail t)

-- | Depth-0 comma count, skipping bracket/paren/brace-nested commas (array
-- subscripts, initializer lists, call args) and any comma inside a
-- double-quoted string literal (a plain open/close toggle -- doesn't
-- handle a doubled @""@-escaped quote inside a string, a known residual
-- gap for that specific case).
countTopLevelCommas :: Text -> Int
countTopLevelCommas = go (0 :: Int) False (0 :: Int)
  where
    go _     _     acc t | T.null t = acc
    go depth inStr acc t = case T.head t of
        '"'                            -> go depth (not inStr) acc (T.tail t)
        _ | inStr                      -> go depth inStr acc (T.tail t)
        c | c `elem` ("([{" :: String) -> go (depth + 1) inStr acc (T.tail t)
        c | c `elem` (")]}" :: String) -> go (max 0 (depth - 1)) inStr acc (T.tail t)
        ',' | depth == 0               -> go depth inStr (acc + 1) (T.tail t)
        _                              -> go depth inStr acc (T.tail t)

-- | Drop every `/* ... */` block comment span (comment markers seen
-- outside a double-quoted string only, so a literal @/*@ inside a string
-- isn't mistaken for one). Confirmed load-bearing on the real corpus: PB
-- source comments are free-form English prose, not code, so English
-- sentence punctuation (a semicolon mid-sentence splits a
-- 'declaredNamesInLine' segment; a comma-joined list reads as a
-- declarator list) reliably produces false-positive raw-side matches
-- otherwise. Applied to the whole file before 'normalizeText' so its own
-- continuation-joining runs on already-comment-free text.
stripBlockComments :: Text -> Text
stripBlockComments = T.concat . reverse . go False False []
  where
    go :: Bool -> Bool -> [Text] -> Text -> [Text]
    go _     _         acc t | T.null t = acc
    go inStr inComment acc t
        | inComment = case T.stripPrefix "*/" t of
            Just rest -> go inStr False acc rest
            Nothing   -> go inStr inComment acc (T.drop 1 t)
        | inStr, Just rest <- T.stripPrefix "\"" t =
            go False inComment (T.singleton '"' : acc) rest
        | inStr =
            go inStr inComment (T.singleton (T.head t) : acc) (T.drop 1 t)
        -- A `//` line comment is skipped wholesale (not scanned char-by-
        -- char) so a decorative banner like `//****...` -- whose 2nd/3rd
        -- characters are literally "/*" -- can never be misread as a real
        -- block comment opener (corpus-confirmed: this is the single most
        -- common comment style across the example corpus).
        | Just _    <- T.stripPrefix "//" t =
            let (thisLine, rest) = T.break (== '\n') t
            in go inStr inComment (thisLine : acc) rest
        | Just rest <- T.stripPrefix "/*" t = go inStr True acc rest
        | Just rest <- T.stripPrefix "\"" t =
            go True inComment (T.singleton '"' : acc) rest
        | otherwise =
            go inStr inComment (T.singleton (T.head t) : acc) (T.drop 1 t)

-- | Sum of 'declaredNamesInLine' over every logical line in the file,
-- excluding lines inside a `[global|shared|type] variables ... end
-- variables` block -- those are 'VarDecl' declarations, out of this
-- check's scope (see the module-level note above), and would otherwise
-- inflate the raw side relative to the 'BsLocalVar'-only extracted side
-- (confirmed: real corpus `.sru` files have exactly this shape).
-- 'normalizeText' (shared preprocessing, not 'PB.Grammar.*') joins '&'
-- continuations first, so a declarator list split across physical lines
-- is still seen as one line here, matching how the real statement
-- splitter sees it.
rawCommaDeclaredNameTotal :: Text -> Int
rawCommaDeclaredNameTotal src = go False (normalizeText (stripBlockComments src))
  where
    go :: Bool -> [LogicalLine] -> Int
    go _      []         = 0
    go inVars (ll : rest)
        | isVarsOpener line = go True rest
        | isVarsCloser line = go False rest
        | inVars             = go inVars rest
        | otherwise          = declaredNamesInLine (llText ll) + go inVars rest
      where line = T.toLower (T.strip (llText ll))

    isVarsOpener t = t == "variables"
                   || "global variables" `T.isPrefixOf` t
                   || "shared variables" `T.isPrefixOf` t
                   || "type variables"   `T.isPrefixOf` t
    isVarsCloser t = "end variables" `T.isPrefixOf` t

-- | Every 'BsLocalVar' leaf reachable from a body, paired with its source
-- line. 'PB.Grammar.Body.pBodyStmt' assigns the same line to every
-- 'BodyStmt' split out of one comma statement
-- (@map (Located ln) . classifyBodyStmt@) -- so grouping by line recovers
-- exactly which extracted names came from one original comma statement.
collectLocalVarLines :: [Located BodyStmt] -> [Int]
collectLocalVarLines = concatMap go
  where
    go (Located ln stmt) = case stmt of
        BsLocalVar{} -> [ln]
        BsIf (IfStmt _ thenB eifs elseB) ->
            collectLocalVarLines thenB
            ++ concatMap (collectLocalVarLines . eifBody) eifs
            ++ maybe [] collectLocalVarLines elseB
        BsFor (ForStmt _ _ _ _ body)      -> collectLocalVarLines body
        BsDo (DoStmt _ body _)            -> collectLocalVarLines body
        BsChoose (ChooseStmt _ clauses)   -> concatMap (collectLocalVarLines . ccBody) clauses
        BsTry (TryStmt body catches mFin) ->
            collectLocalVarLines body ++ concatMap (collectLocalVarLines . catchBody) catches
            ++ maybe [] collectLocalVarLines mFin
        _ -> []

-- | Sum of extracted 'BsLocalVar' names, restricted to lines that produced
-- 2+ of them (i.e. came from a real comma statement) -- symmetric with
-- 'rawCommaDeclaredNameTotal's "only lines with a comma count".
extractedCommaLocalVarTotal :: SrFile -> Int
extractedCommaLocalVarTotal sf =
    sum (filter (>= 2) (Map.elems lineCounts))
  where
    lineCounts = Map.fromListWith (+) [(ln, 1 :: Int) | ln <- collectLocalVarLines (allBodies sf)]
    allBodies s =
        concatMap fbBody (srFunctions s)
        ++ concatMap sbBody (srSubroutines s)
        ++ concatMap evBody (srEvents s)
        ++ concatMap obBody (srOnBlocks s)
        ++ concatMap tbBody (srTypeBlocks s)

chkCommaDeclaredNamesMatch :: IO [(FilePath, Text)]
chkCommaDeclaredNamesMatch = do
    files <- loadTypedCorpus
    pure
        [ (path, msg)
        | (path, src, sf) <- files
        , let raw       = rawCommaDeclaredNameTotal src
        , let extracted = extractedCommaLocalVarTotal sf
        , raw /= extracted
        , let msg = "raw comma-declarator count " <> T.pack (show raw)
                  <> " != extracted BsLocalVar count " <> T.pack (show extracted)
        ]

-- ---------------------------------------------------------------------------
-- Self-test fixtures: hand-built 'Value's matching the real
-- 'PB.Pipeline.Serialise' wire shape (confirmed via 'cabal repl' against the
-- real 'ToJSON' instances, not guessed from field names), each deliberately
-- violating one of the node checks above. Proves each check actually fires
-- -- these ten checks previously compared against tag strings/field paths
-- that could never match a real encoded node, so every one of them was a
-- silent no-op regardless of corpus content.

lvalueJson :: [Value] -> Value
lvalueJson segs = object ["segments" .= segs]

emptySegLvalue, oneSegLvalue :: Value
emptySegLvalue = lvalueJson []
oneSegLvalue   = lvalueJson [object ["name" .= ("x" :: Text), "subscript" .= Null]]

exRawJson :: [Text] -> Value
exRawJson toks = object ["tag" .= ("ExRaw" :: Text), "contents" .= toks]

emptyExRaw, nonEmptyExRaw :: Value
emptyExRaw    = exRawJson []
nonEmptyExRaw = exRawJson ["1"]

selfTestFixtures :: TestTree
selfTestFixtures = testGroup "Corpus.Invariants.SelfTest"
    [ fires "chkLvalueSegs fires on ExLvalue with empty segments" chkLvalueSegs $
        object ["tag" .= ("ExLvalue" :: Text), "contents" .= emptySegLvalue]
    , fires "chkCallExprCallee fires on ExCall with empty callee segments" chkCallExprCallee $
        object ["tag" .= ("ExCall" :: Text), "callee" .= emptySegLvalue, "args" .= ([] :: [Value])]
    , fires "chkAssignLhs fires on BsAssign with empty lhs segments" chkAssignLhs $
        object ["tag" .= ("BsAssign" :: Text), "contents" .= [emptySegLvalue, nonEmptyExRaw]]
    , fires "chkHostVarSegs fires on ExHostVar with empty segments" chkHostVarSegs $
        object ["tag" .= ("ExHostVar" :: Text), "contents" .= emptySegLvalue]
    , fires "chkForVarSegs fires on BsFor with empty var segments" chkForVarSegs $
        object [ "tag" .= ("BsFor" :: Text)
               , "contents" .= object
                   [ "var" .= emptySegLvalue, "from" .= nonEmptyExRaw, "to" .= nonEmptyExRaw
                   , "step" .= Null, "body" .= ([] :: [Value]) ] ]
    , fires "chkNoEmptyExRaw fires on empty ExRaw" chkNoEmptyExRaw emptyExRaw
    , fires "chkBinopOperands fires on ExBinOp with empty ExRaw operand" chkBinopOperands $
        object ["tag" .= ("ExBinOp" :: Text), "lhs" .= emptyExRaw, "op" .= ("BopAdd" :: Text), "rhs" .= nonEmptyExRaw]
    , fires "chkIfCond fires on BsIf with empty ExRaw cond" chkIfCond $
        object [ "tag" .= ("BsIf" :: Text)
               , "contents" .= object
                   [ "cond" .= emptyExRaw, "then" .= ([] :: [Value])
                   , "elseIfs" .= ([] :: [Value]), "else" .= Null ] ]
    , fires "chkForBounds fires on BsFor with empty ExRaw from/to" chkForBounds $
        object [ "tag" .= ("BsFor" :: Text)
               , "contents" .= object
                   [ "var" .= oneSegLvalue, "from" .= emptyExRaw, "to" .= nonEmptyExRaw
                   , "step" .= Null, "body" .= ([] :: [Value]) ] ]
    , fires "chkChooseExpr fires on BsChoose with empty ExRaw expr" chkChooseExpr $
        object [ "tag" .= ("BsChoose" :: Text)
               , "contents" .= object ["expr" .= emptyExRaw, "clauses" .= ([] :: [Value])] ]
    ]
  where
    fires name check fixture = testCase name $
        assertBool (name <> " did not fire on a deliberately-broken fixture") (not (null (check fixture)))

-- ---------------------------------------------------------------------------
-- Test tree

invariant :: String -> NodeCheck -> TestTree
invariant name check = testCase name $ do
    viols <- runNodeCheck check
    assertNoViolations name viols

fileInvariant :: String -> (FilePath -> Value -> [Text]) -> TestTree
fileInvariant name check = testCase name $ do
    viols <- runFileCheck check
    assertNoViolations name viols

invariantDw :: String -> NodeCheck -> TestTree
invariantDw name check = testCase name $ do
    viols <- runDwNodeCheck check
    assertNoViolations name viols

fileInvariantDw :: String -> (FilePath -> Value -> [Text]) -> TestTree
fileInvariantDw name check = testCase name $ do
    viols <- runDwFileCheck check
    assertNoViolations name viols

tests :: TestTree
tests = testGroup "Corpus.Invariants"
    [ testCase "corpus loader resolves 250+ files regardless of cwd" $ do
        pairs <- loadCorpus
        assertBool
            ("loadCorpus found only " <> show (length pairs)
              <> " parsed files -- expected 250+; this is the exact vacuous-corpus \
                 \regression RepoRoot exists to prevent")
            (length pairs >= 250)
    , invariant "lvalue segments non-empty"          chkLvalueSegs
    , invariant "call_expr callee non-empty"         chkCallExprCallee
    , invariant "assign lhs non-empty"               chkAssignLhs
    , invariant "host_var lvalue segments non-empty" chkHostVarSegs
    , invariant "for var segments non-empty"         chkForVarSegs
    , invariant "no empty ExRaw anywhere"            chkNoEmptyExRaw
    , invariant "binop operands not empty ExRaw"     chkBinopOperands
    , invariant "if cond not empty ExRaw"            chkIfCond
    , invariant "for bounds not empty ExRaw"         chkForBounds
    , invariant "choose expr not empty ExRaw"        chkChooseExpr
    , fileInvariant "function sig.name non-empty"    chkFnNames
    , fileInvariant "subroutine sig.name non-empty"  chkSubNames
    , selfTestFixtures
    , testCase "comma-declarator count: raw text matches extracted BsLocalVar count" $ do
        viols <- chkCommaDeclaredNamesMatch
        assertNoViolations "comma-declarator count" viols
    , testGroup "Corpus.Meta.PS"
        [ fileInvariant "callable blocks have meta.file"                 chkPsMetaFile
        , fileInvariant "callable blocks have meta.object"               chkPsMetaObject
        , fileInvariant "callable blocks have meta.startLine > 0"        chkPsMetaStartLine
        , fileInvariant "callable blocks have meta.endLine >= startLine"  chkPsMetaEndLine
        ]
    , testGroup "Corpus.DW.Invariants"
        [ fileInvariantDw "DW files not stub"                   chkDwNotStub
        , fileInvariantDw "DW bands non-empty"                  chkDwBandsNonEmpty
        , invariantDw     "column control has id"                chkDwColumnControlHasId
        , invariantDw     "table column name non-empty"          chkDwTableColumnNameNonEmpty
        , fileInvariantDw "dtArguments == drArguments count"     chkDwArgConsistency
        ]
    ]
