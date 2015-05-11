{-# LANGUAGE OverloadedStrings, TupleSections, FlexibleContexts #-}
-- | This program is a convenience utility for running the Futhark
-- test suite, and its test programs.
module Main ( ProgramTest (..)
            , TestRun (..)
            , TestCase (..)
            , main) where

import Control.Applicative
import Control.Concurrent
import Control.Monad hiding (forM_)
import Control.Exception hiding (try)
import Control.Monad.Except hiding (forM_)
import Data.Char
import Data.List
import Data.Monoid
import Data.Ord
import Data.Foldable (forM_)
import qualified Data.Array as A
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.HashMap.Lazy as HM
import System.Console.GetOpt
import System.Directory
import System.Process
import System.Exit
import System.IO
import System.FilePath

import Text.Parsec hiding ((<|>), many, optional)
import Text.Parsec.Text
import Text.Parsec.Error
import Text.Regex.TDFA

import Prelude

import Futhark.Representation.AST.Pretty (pretty)
import Futhark.Representation.AST.Syntax.Core hiding (Basic)
import Futhark.Internalise.TypesValues (internaliseValue)
import qualified Language.Futhark.Parser as F
import Futhark.Metrics
import Futhark.Pipeline
import Futhark.Compiler
import Futhark.Passes (standardPipeline)

import Futhark.Util.Options

-- | Number of tests to run concurrently.
concurrency :: Int
concurrency = 8

---
--- Test specification parser
---

-- | Description of a test to be carried out on a Futhark program.
-- The Futhark program is stored separately.
data ProgramTest =
  ProgramTest { testDescription ::
                   T.Text
              , testAction ::
                   TestAction
              , testExpectedStructure ::
                   Maybe AstMetrics
              }
  deriving (Show)

data TestAction
  = CompileTimeFailure ExpectedError
  | RunCases [TestRun]
  deriving (Show)

data ExpectedError = AnyError
                   | ThisError T.Text Regex

instance Show ExpectedError where
  show AnyError = "AnyError"
  show (ThisError r _) = "ThisError " ++ show r

data RunMode
  = CompiledOnly
  | InterpretedOnly
  | InterpretedAndCompiled
  deriving (Eq, Show)

data TestRun = TestRun
               { runMode :: RunMode
               , runInput :: Values
               , runExpectedResult :: ExpectedResult Values
               }
             deriving (Show)

data Values = Values [Value]
            | InFile FilePath
            deriving (Show)

data ExpectedResult values
  = Succeeds values
  | RunTimeFailure ExpectedError
  deriving (Show)

lexeme :: Parser a -> Parser a
lexeme p = p <* spaces

lexstr :: String -> Parser ()
lexstr = void . lexeme . string

braces :: Parser a -> Parser a
braces p = lexstr "{" *> p <* lexstr "}"

parseNatural :: Parser Int
parseNatural = lexeme $ foldl (\acc x -> acc * 10 + x) 0 <$>
               map num <$> some digit
  where num c = ord c - ord '0'

parseDescription :: Parser T.Text
parseDescription = lexeme $ T.pack <$> (anyChar `manyTill` descriptionSeparator)

descriptionSeparator :: Parser ()
descriptionSeparator = try (string "--" >> void newline) <|> eof

parseAction :: Parser TestAction
parseAction = CompileTimeFailure <$> (lexstr "error:" *> parseExpectedError) <|>
              RunCases <$> parseRunCases

parseRunMode :: Parser RunMode
parseRunMode = (lexstr "compiled" *> pure CompiledOnly) <|>
               pure InterpretedAndCompiled

parseRunCases :: Parser [TestRun]
parseRunCases = many $ TestRun <$> parseRunMode <*> parseInput <*> parseExpectedResult

parseExpectedResult :: Parser (ExpectedResult Values)
parseExpectedResult = (Succeeds <$> (lexstr "output" *> parseValues)) <|>
                 (RunTimeFailure <$> (lexstr "error:" *> parseExpectedError))

parseExpectedError :: Parser ExpectedError
parseExpectedError = lexeme $ do
  s <- restOfLine
  if T.all isSpace s
    then return AnyError
         -- blankCompOpt creates a regular expression that treats
         -- newlines like ordinary characters, which is what we want.
    else ThisError s <$> makeRegexOptsM blankCompOpt defaultExecOpt (T.unpack s)

parseInput :: Parser Values
parseInput = lexstr "input" *> parseValues

parseValues :: Parser Values
parseValues = do s <- parseBlock
                 case parseValuesFromString "input" $ T.unpack s of
                   Left err -> fail $ show err
                   Right vs -> return $ Values vs
              <|> lexstr "@" *> lexeme (InFile <$> T.unpack <$> restOfLine)

parseValuesFromString :: SourceName -> String -> Either F.ParseError [Value]
parseValuesFromString srcname s =
  liftM concat $ mapM internalise =<< F.parseValues F.RealAsFloat64 srcname s
  where internalise v =
          maybe (Left $ F.ParseError $ "Invalid input value: " ++ pretty v) Right $
          internaliseValue v

parseBlock :: Parser T.Text
parseBlock = lexeme $ braces (T.pack <$> parseBlockBody 0)

parseBlockBody :: Int -> Parser String
parseBlockBody n = do
  c <- lookAhead anyChar
  case (c,n) of
    ('}', 0) -> return mempty
    ('}', _) -> (:) <$> anyChar <*> parseBlockBody (n-1)
    ('{', _) -> (:) <$> anyChar <*> parseBlockBody (n+1)
    _        -> (:) <$> anyChar <*> parseBlockBody n

restOfLine :: Parser T.Text
restOfLine = T.pack <$> (anyChar `manyTill` (void newline <|> eof))

parseExpectedStructure :: Parser AstMetrics
parseExpectedStructure = do
  lexstr "structure"
  braces $ liftM HM.fromList $ many $
    (,) <$> (T.pack <$> lexeme (many1 (satisfy isAlpha))) <*> parseNatural

testSpec :: Parser ProgramTest
testSpec =
  ProgramTest <$> parseDescription <*> parseAction <*> optional parseExpectedStructure

readTestSpec :: SourceName -> T.Text -> Either ParseError ProgramTest
readTestSpec = parse $ testSpec <* eof

commentPrefix :: T.Text
commentPrefix = "//"

fixPosition :: ParseError -> ParseError
fixPosition err =
  let newpos = incSourceColumn (errorPos err) $ T.length commentPrefix
  in setErrorPos newpos err

testSpecFromFile :: FilePath -> IO ProgramTest
testSpecFromFile path = do
  s <- T.unlines <$>
       map (T.drop 2) <$>
       takeWhile (commentPrefix `T.isPrefixOf`) <$>
       T.lines <$>
       T.readFile path
  case readTestSpec path s of
    Left err -> error $ show $ fixPosition err
    Right v  -> return v

---
--- Test execution
---

type TestM = ExceptT String IO

runTestM :: TestM () -> IO TestResult
runTestM = liftM (either Failure $ const Success) . runExceptT

io :: IO a -> TestM a
io = liftIO

context :: String -> TestM a -> TestM a
context s = withExceptT ((s ++ ":\n") ++)

data TestResult = Success
                | Failure String
                deriving (Eq, Show)

data TestCase = TestCase { testCaseProgram :: FilePath
                         , testCaseTest :: ProgramTest
                         , testCasePrograms :: ProgConfig
                         }
                deriving (Show)

instance Eq TestCase where
  x == y = testCaseProgram x == testCaseProgram y

instance Ord TestCase where
  x `compare` y = testCaseProgram x `compare` testCaseProgram y

data RunResult = ErrorResult Int String
               | SuccessResult [Value]

progNotFound :: String -> String
progNotFound s = s ++ ": command not found"

optimisedProgramMetrics :: FilePath -> TestM AstMetrics
optimisedProgramMetrics program = do
  res <- io $ runPipelineOnProgram newFutharkConfig program
  case res of
    (_, Left err) ->
      throwError $ show $ errorDesc err
    (_, Right (Basic prog)) ->
      return $ progMetrics prog
    (_, Right (ExplicitMemory _)) ->
      throwError "Compiling for metrics resulted in non-basic program"

testMetrics :: FilePath -> AstMetrics -> TestM ()
testMetrics program expected = context "Checking metrics" $ do
  actual <- optimisedProgramMetrics program
  mapM_ (ok actual) $ HM.toList expected
  where ok metrics (name, expected_occurences) =
          case HM.lookup name metrics of
            Nothing
              | expected_occurences > 0 ->
              throwError $ T.unpack name ++ " should have occurred " ++ show expected_occurences ++
              " times, but did not occur at all in optimised program."
            Just actual_occurences
              | expected_occurences /= actual_occurences ->
                throwError $ T.unpack name ++ " should have occurred " ++ show expected_occurences ++
              " times, but occured " ++ show actual_occurences ++ " times."
            _ -> return ()

runTestCase :: TestCase -> TestM ()
runTestCase (TestCase program testcase progs) = do
  forM_ (testExpectedStructure testcase) $ testMetrics program

  case testAction testcase of

    CompileTimeFailure expected_error ->
      forM_ (configTypeCheckers progs) $ \typeChecker ->
        context ("Type-checking with " ++ typeChecker) $ do
          (code, _, err) <-
            io $ readProcessWithExitCode typeChecker [program] ""
          case code of
           ExitSuccess -> throwError "Expected failure\n"
           ExitFailure 127 -> throwError $ progNotFound typeChecker
           ExitFailure 1 -> throwError err
           ExitFailure _ -> checkError expected_error err

    RunCases [] ->
      forM_ (configCompilers progs) $ \compiler ->
      context ("Compiling with " ++ compiler) $
      justCompileTestProgram compiler program

    RunCases run_cases ->
      forM_ run_cases $ \run -> do
        unless (runMode run == CompiledOnly) $
          forM_ (configInterpreters progs) $ \interpreter ->
            context ("Interpreting with " ++ interpreter) $
              mapM (interpretTestProgram interpreter program) run_cases

        unless (runMode run == InterpretedOnly) $
          forM_ (configCompilers progs) $ \compiler ->
            context ("Compiling with " ++ compiler) $
              mapM (compileTestProgram compiler program) run_cases

checkError :: ExpectedError -> String -> TestM ()
checkError (ThisError regex_s regex) err
  | not (match regex err) =
     throwError $ "Expected error:\n  " ++ T.unpack regex_s ++
     "\nGot error:\n  " ++ err
checkError _ _ =
  return ()

runResult :: ExitCode -> String -> String -> TestM RunResult
runResult ExitSuccess stdout_s _ =
  case parseValuesFromString "stdout" stdout_s of
    Left e   -> throwError $ show e
    Right vs -> return $ SuccessResult vs
runResult (ExitFailure code) _ stderr_s =
  return $ ErrorResult code stderr_s

getValues :: MonadIO m => FilePath -> Values -> m [Value]
getValues _ (Values vs) =
  return vs
getValues dir (InFile file) = do
  s <- liftIO $ readFile file'
  case parseValuesFromString file' s of
    Left e   -> fail $ show e
    Right vs -> return vs
  where file' = dir </> file

getExpectedResult :: MonadIO m =>
                     FilePath -> ExpectedResult Values -> m (ExpectedResult [Value])
getExpectedResult dir (Succeeds vals)      = liftM Succeeds $ getValues dir vals
getExpectedResult _   (RunTimeFailure err) = return $ RunTimeFailure err

interpretTestProgram :: String -> FilePath -> TestRun -> TestM ()
interpretTestProgram futharki program (TestRun _ inputValues expectedResult) = do
  input <- intercalate "\n" <$> map pretty <$> getValues dir inputValues
  expectedResult' <- getExpectedResult dir expectedResult
  (code, output, err) <- io $ readProcessWithExitCode futharki [program] input
  case code of
    ExitFailure 127 ->
      throwError $ progNotFound futharki
    _               ->
      compareResult program expectedResult' =<< runResult code output err
  where dir = takeDirectory program

compileTestProgram :: String -> FilePath -> TestRun -> TestM ()
compileTestProgram futharkc program (TestRun _ inputValues expectedResult) = do
  input <- intercalate "\n" <$> map pretty <$> getValues dir inputValues
  expectedResult' <- getExpectedResult dir expectedResult
  (futcode, _, futerr) <-
    io $ readProcessWithExitCode futharkc
    [program, "-o", binOutputf] ""
  case futcode of
    ExitFailure 127 -> throwError $ progNotFound futharkc
    ExitFailure _   -> throwError futerr
    ExitSuccess     -> return ()
  -- Explicitly prefixing the current directory is necessary for
  -- readProcessWithExitCode to find the binary when binOutputf has
  -- no path component.
  (progCode, output, progerr) <-
    io $ readProcessWithExitCode ("." </> binOutputf) [] input
  compareResult program expectedResult' =<< runResult progCode output progerr
  where binOutputf = program `replaceExtension` "bin"
        dir = takeDirectory program

justCompileTestProgram :: String -> FilePath -> TestM ()
justCompileTestProgram futharkc program =
  withExceptT compiling $ do
    (futcode, _, futerr) <-
      io $ readProcessWithExitCode futharkc
      [program, "-o", binOutputf] ""
    case futcode of
      ExitFailure 127 -> throwError $ progNotFound futharkc
      ExitFailure _   -> throwError futerr
      ExitSuccess     -> return ()
  where binOutputf = program `replaceExtension` "bin"

        compiling = ("compiling:\n"++)

compareResult :: FilePath -> ExpectedResult [Value] -> RunResult -> TestM ()
compareResult program (Succeeds expectedResult) (SuccessResult actualResult) =
  unless (compareValues actualResult expectedResult) $ do
    actualf <-
      io $ writeOutFile program "actual" $
      unlines $ map pretty actualResult
    expectedf <-
      io $ writeOutFile program "expected" $
      unlines $ map pretty expectedResult
    throwError $ actualf ++ " and " ++ expectedf ++ " do not match."
compareResult _ (RunTimeFailure expectedError) (ErrorResult _ actualError) =
  checkError expectedError actualError
compareResult _ (Succeeds _) (ErrorResult _ err) =
  throwError $ "Program failed with error:\n  " ++ err
compareResult _ (RunTimeFailure f) (SuccessResult _) =
  throwError $ "Program succeeded, but expected failure:\n  " ++ show f

writeOutFile :: FilePath -> String -> String -> IO FilePath
writeOutFile base ext content =
  attempt (0::Int)
  where template = base `replaceExtension` ext
        attempt i = do
          let filename = template ++ "-" ++ show i
          exists <- doesFileExist filename
          if exists
            then attempt $ i+1
            else do writeFile filename content
                    return filename

compareValues :: [Value] -> [Value] -> Bool
compareValues vs1 vs2
  | length vs1 /= length vs2 = False
  | otherwise = and $ zipWith compareValue vs1 vs2

compareValue :: Value -> Value -> Bool
compareValue (BasicVal bv1) (BasicVal bv2) =
  compareBasicValue bv1 bv2
compareValue (ArrayVal vs1 _ _) (ArrayVal vs2 _ _) =
  A.bounds vs1 == A.bounds vs2 &&
  and (zipWith compareBasicValue (A.elems vs1) (A.elems vs2))
compareValue _ _ =
  False

compareBasicValue :: BasicValue -> BasicValue -> Bool
compareBasicValue (Float32Val x) (Float32Val y) = floatToDouble (abs (x - y)) < epsilon
compareBasicValue (Float64Val x) (Float64Val y) = abs (x - y) < epsilon
compareBasicValue (Float64Val x) (Float32Val y) = abs (x - floatToDouble y) < epsilon
compareBasicValue (Float32Val x) (Float64Val y) = abs (floatToDouble x - y) < epsilon
compareBasicValue x y = x == y

epsilon :: Double
epsilon = 0.001

floatToDouble :: Float -> Double
floatToDouble x =
  let (m,n) = decodeFloat x
  in encodeFloat m n

---
--- Test manager
---

catching :: IO TestResult -> IO TestResult
catching m = m `catch` save
  where save :: SomeException -> IO TestResult
        save e = return $ Failure $ show e

doTest :: TestCase -> IO TestResult
doTest = catching . runTestM . runTestCase

makeTestCase :: ProgConfig -> TestMode -> FilePath -> IO TestCase
makeTestCase progs mode file = do
  spec <- applyMode mode <$> testSpecFromFile file
  return $ TestCase file spec progs

applyMode :: TestMode -> ProgramTest -> ProgramTest
applyMode mode test =
  test { testAction = applyModeToAction mode $ testAction test }

applyModeToAction :: TestMode -> TestAction -> TestAction
applyModeToAction _ a@(CompileTimeFailure {}) =
  a
applyModeToAction OnlyTypeCheck (RunCases _) =
  RunCases []
applyModeToAction mode (RunCases cases) =
  RunCases $ map (applyModeToCase mode) cases

applyModeToCase :: TestMode -> TestRun -> TestRun
applyModeToCase OnlyInterpret run =
  run { runMode = InterpretedOnly }
applyModeToCase OnlyCompile run =
  run { runMode = CompiledOnly }
applyModeToCase _ run =
  run

runTest :: MVar TestCase -> MVar (TestCase, TestResult) -> IO ()
runTest testmvar resmvar = forever $ do
  test <- takeMVar testmvar
  res <- doTest test
  putMVar resmvar (test, res)

clearLine :: IO ()
clearLine = putStr "\27[2K"

reportInteractive :: String -> Int -> Int -> Int -> IO ()
reportInteractive first failed passed remaining = do
  clearLine
  putStr $
    "\rWaiting for " ++ first ++ " (" ++
    show failed ++ " failed, " ++
    show passed ++ " passed, " ++
    show remaining ++ " to go.)\r"
  hFlush stdout

reportText :: String -> Int -> Int -> Int -> IO ()
reportText first failed passed remaining =
  putStr $ "Waiting for " ++ first ++ " (" ++
         show failed ++ " failed, " ++
         show passed ++ " passed, " ++
         show remaining ++ " to go.)\n"

runTests :: TestConfig -> [FilePath] -> IO ()
runTests config files = do
  let mode = configTestMode config
  testmvar <- newEmptyMVar
  resmvar <- newEmptyMVar
  replicateM_ concurrency $ forkIO $ runTest testmvar resmvar
  tests <- mapM (makeTestCase (configPrograms config) mode) files
  _ <- forkIO $ mapM_ (putMVar testmvar) tests
  isTTY <- hIsTerminalDevice stdout

  let report = if isTTY then reportInteractive else reportText
      clear  = if isTTY then clearLine else putStr "\n"
      getResults remaining failed passed =
        case S.toList remaining of
          []      -> clear >> return (failed, passed)
          first:_ -> do
            report (testCaseProgram first) failed passed $ S.size remaining
            (test, res) <- takeMVar resmvar
            let next = getResults $ test `S.delete` remaining
            case res of
              Success -> next failed (passed+1)
              Failure s -> do clear
                              putStrLn (testCaseProgram test ++ ":\n" ++ s)
                              next (failed+1) passed

  (failed, passed) <- getResults (S.fromList tests) 0 0
  putStrLn $ show failed ++ " failed, " ++ show passed ++ " passed."
  exitWith $ case failed of 0 -> ExitSuccess
                            _ -> ExitFailure 1

---
--- Configuration and command line parsing
---

data TestConfig = TestConfig
                  { configTestMode :: TestMode
                  , configPrograms :: ProgConfig
                  }

defaultConfig :: TestConfig
defaultConfig = TestConfig { configTestMode = Everything
                           , configPrograms =
                             ProgConfig
                             { configCompiler = Left "futhark-c"
                             , configInterpreter = Left "futharki"
                             , configTypeChecker = Left "futhark"
                             }
                           }

data ProgConfig = ProgConfig
                  { configCompiler :: Either FilePath [FilePath]
                  , configInterpreter :: Either FilePath [FilePath]
                  , configTypeChecker :: Either FilePath [FilePath]
                  }
                  deriving (Show)

changeProgConfig :: (ProgConfig -> ProgConfig) -> TestConfig -> TestConfig
changeProgConfig f config = config { configPrograms = f $ configPrograms config }

configCompilers :: ProgConfig -> [FilePath]
configCompilers = either pure id . configCompiler

configInterpreters :: ProgConfig -> [FilePath]
configInterpreters = either pure id . configInterpreter

configTypeCheckers :: ProgConfig -> [FilePath]
configTypeCheckers = either pure id . configTypeChecker

addCompiler :: FilePath -> ProgConfig -> ProgConfig
addCompiler compiler config = case configCompiler config of
  Left _ -> config { configCompiler = Right [compiler] }
  Right existing -> config { configCompiler = Right $ compiler : existing }

addInterpreter :: FilePath -> ProgConfig -> ProgConfig
addInterpreter interpreter config = case configInterpreter config of
  Left _ -> config { configInterpreter = Right [interpreter] }
  Right existing -> config { configInterpreter = Right $ interpreter : existing }

addTypeChecker :: FilePath -> ProgConfig -> ProgConfig
addTypeChecker typeChecker config = case configTypeChecker config of
  Left _ -> config { configTypeChecker = Right [typeChecker] }
  Right existing -> config { configTypeChecker = Right $ typeChecker : existing }

data TestMode = OnlyTypeCheck
              | OnlyCompile
              | OnlyInterpret
              | Everything

commandLineOptions :: [FunOptDescr TestConfig]
commandLineOptions = [
    Option "t" ["only-typecheck"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyTypeCheck })
    "Only perform type-checking"
  , Option "i" ["only-interpret"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyInterpret })
    "Only interpret"
  , Option "c" ["only-compile"]
    (NoArg $ Right $ \config -> config { configTestMode = OnlyCompile })
    "Only run compiled code"

  , Option [] ["typechecker"]
    (ReqArg (Right . changeProgConfig . addTypeChecker)
     "PROGRAM")
    "What to run for type-checking (defaults to 'futhark')."
  , Option [] ["compiler"]
    (ReqArg (Right . changeProgConfig . addCompiler)
     "PROGRAM")
    "What to run for code generation (defaults to 'futhark-c')."
  , Option [] ["interpreter"]
    (ReqArg (Right . changeProgConfig . addInterpreter)
     "PROGRAM")
    "What to run for interpretation (defaults to 'futharki')."
  ]

main :: IO ()
main = mainWithOptions defaultConfig commandLineOptions $ \progs config ->
  Just $ runTests config progs