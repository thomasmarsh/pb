module CorpusTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text         as T

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

lookupObj :: Text -> Value -> Value
lookupObj k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
lookupObj _ _          = Null

arrayLen :: Value -> Int
arrayLen (Array v) = length (toList v)
arrayLen _         = 0

firstOf :: Value -> Value
firstOf (Array v) = case toList v of { (x : _) -> x ; [] -> Null }
firstOf _         = Null

runCorpusFile :: FilePath -> IO Value
runCorpusFile path = do
  src <- readFile path
  case runFile path src of
    Left err -> assertFailure (T.unpack err)
    Right v  -> pure v

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Corpus.Golden"
  [ testCase "f_get_profile.srf" $ do
      v <- runCorpusFile "example/PowerBuilder-Example/export/pbexamfe.pbl/f_get_profile.srf"
      arrayLen (lookupObj "headers"    v)                              @?= 2
      lookupObj "forward"              v                               @?= Null
      arrayLen (lookupObj "decls" (lookupObj "prototypes" v))          @?= 1
      arrayLen (lookupObj "typeBlocks" v)                              @?= 1
      let tb0decl = lookupObj "decl" (firstOf (lookupObj "typeBlocks" v))
      lookupObj "name"     tb0decl                                     @?= String "f_get_profile"
      lookupObj "ancestor" tb0decl                                     @?= String "function_object"
      arrayLen (lookupObj "functions"  v)                              @?= 1
      let sig = lookupObj "sig" (firstOf (lookupObj "functions" v))
      lookupObj "name"       sig                                       @?= String "f_get_profile"
      lookupObj "returnType" sig                                       @?= String "integer"
      arrayLen (lookupObj "onBlocks"   v)                              @?= 0

  , testCase "u_st.sru" $ do
      v <- runCorpusFile "example/PowerBuilder-Example/export/pbexamuo.pbl/u_st.sru"
      arrayLen (lookupObj "headers"    v)                              @?= 2
      let fwdTypes = lookupObj "types" (lookupObj "forward" v)
      arrayLen fwdTypes                                                @?= 1
      lookupObj "name"     (firstOf fwdTypes)                          @?= String "u_st"
      lookupObj "ancestor" (firstOf fwdTypes)                          @?= String "pfc_u_st"
      lookupObj "prototypes" v                                         @?= Null
      arrayLen (lookupObj "typeBlocks"      v)                         @?= 1
      arrayLen (lookupObj "globalInstances" v)                         @?= 1
      let gi0 = firstOf (lookupObj "globalInstances" v)
      lookupObj "name" gi0                                             @?= String "u_st"
      lookupObj "type" gi0                                             @?= String "u_st"
      arrayLen (lookupObj "functions"  v)                              @?= 0
      arrayLen (lookupObj "onBlocks"   v)                              @?= 0

  , testCase "w_nested_criteria.srw" $ do
      v <- runCorpusFile "example/PowerBuilder-Example/export/pbexamw2.pbl/w_nested_criteria.srw"
      arrayLen (lookupObj "headers"    v)                              @?= 2
      arrayLen (lookupObj "types" (lookupObj "forward" v))             @?= 1
      lookupObj "prototypes" v                                         @?= Null
      arrayLen (lookupObj "typeBlocks"      v)                         @?= 2
      arrayLen (lookupObj "onBlocks"        v)                         @?= 2
      arrayLen (lookupObj "globalInstances" v)                         @?= 1
      arrayLen (lookupObj "functions"       v)                         @?= 0

  , testCase "m_lv_rmb_prod.srm" $ do
      v <- runCorpusFile "example/PowerBuilder-Example/export/pbexammn.pbl/m_lv_rmb_prod.srm"
      arrayLen (lookupObj "headers"    v)                              @?= 2
      arrayLen (lookupObj "types" (lookupObj "forward" v))             @?= 1
      arrayLen (lookupObj "typeBlocks"      v)                         @?= 1
      arrayLen (lookupObj "onBlocks"        v)                         @?= 3
      arrayLen (lookupObj "globalInstances" v)                         @?= 1
      arrayLen (lookupObj "functions"       v)                         @?= 0
  ]
