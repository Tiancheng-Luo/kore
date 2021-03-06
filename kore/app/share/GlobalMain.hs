{-# LANGUAGE TemplateHaskell #-}

module GlobalMain
    ( MainOptions(..)
    , GlobalOptions(..)
    , KoreProveOptions(..)
    , KoreMergeOptions(..)
    , ExeName (..)
    , Main
    , parseKoreProveOptions
    , parseKoreMergeOptions
    , mainGlobal
    , defaultMainGlobal
    , enableDisableFlag
    , clockSomething
    , clockSomethingIO
    , mainPatternVerify
    , parseDefinition
    , parseModuleName
    , verifyDefinitionWithBase
    , mainParse
    , lookupMainModule
    , LoadedDefinition
    , LoadedModule
    , loadDefinitions
    , loadModule
    ) where

import Prelude.Kore

import Control.Exception
    ( evaluate
    )
import qualified Control.Monad as Monad
import Data.List
    ( intercalate
    )
import Data.Map.Strict
    ( Map
    )
import qualified Data.Map.Strict as Map
import Data.Text
    ( Text
    , pack
    )
import Data.Time.Format
    ( defaultTimeLocale
    , formatTime
    )
import Data.Time.LocalTime
    ( ZonedTime
    , getZonedTime
    )
import Data.Version
    ( showVersion
    )
import Development.GitRev
    ( gitBranch
    , gitCommitDate
    , gitHash
    )
import GHC.Stack
    ( emptyCallStack
    )

import Options.Applicative
    ( InfoMod
    , Parser
    , ParserHelp (..)
    , argument
    , defaultPrefs
    , disabled
    , execParserPure
    , flag
    , flag'
    , handleParseResult
    , help
    , helper
    , hidden
    , info
    , internal
    , long
    , maybeReader
    , metavar
    , option
    , overFailure
    , readerError
    , str
    , strOption
    , switch
    , value
    , (<**>)
    )
import Options.Applicative.Help.Chunk
    ( Chunk (..)
    , vsepChunks
    )

import qualified Options.Applicative as Options
import qualified Options.Applicative.Help.Pretty as Pretty
import System.Clock
    ( Clock (Monotonic)
    , diffTimeSpec
    , getTime
    )
import qualified System.Environment as Env

import Kore.ASTVerifier.DefinitionVerifier
    ( verifyAndIndexDefinitionWithBase
    )
import Kore.ASTVerifier.PatternVerifier as PatternVerifier
import qualified Kore.Attribute.Symbol as Attribute
    ( Symbol
    )
import qualified Kore.Builtin as Builtin
import Kore.Error
import Kore.IndexedModule.IndexedModule
    ( VerifiedModule
    )
import Kore.Log as Log
import Kore.Parser
    ( ParsedPattern
    , parseKoreDefinition
    )
import Kore.Parser.Lexeme
    ( moduleNameIdParser
    )
import Kore.Parser.ParserUtils
    ( endOfInput
    , parseOnly
    )
import Kore.Step.Strategy
    ( GraphSearchOrder (..)
    )
import Kore.Syntax
import Kore.Syntax.Definition
    ( ModuleName (..)
    , ParsedDefinition
    , getModuleNameForError
    )
import qualified Kore.Verified as Verified
import qualified Paths_kore as MetaData
    ( version
    )
import Text.Read
    ( readMaybe
    )

type Main = LoggerT IO

data KoreProveOptions =
    KoreProveOptions
        { specFileName :: !FilePath
        -- ^ Name of file containing the spec to be proven
        , specMainModule :: !ModuleName
        -- ^ The main module of the spec to be proven
        , graphSearch :: GraphSearchOrder
        -- ^ Search order of the execution graph
        , bmc :: !Bool
        -- ^ Whether to use bounded model checker
        , saveProofs :: !(Maybe FilePath)
        -- ^ The file in which to save the proven claims in case the prover
        -- fails.
        }

parseModuleName :: String -> String -> String -> Parser ModuleName
parseModuleName metaName longName helpMsg =
    option readModuleName
        ( metavar metaName
        <> long longName
        <> help helpMsg
        )

readModuleName :: Options.ReadM ModuleName
readModuleName = do
    opt <- str
    case parseOnly (moduleNameIdParser <* endOfInput) "<command-line>" opt of
        Left err        -> readerError err
        Right something -> pure something

parseKoreProveOptions :: Parser KoreProveOptions
parseKoreProveOptions =
    KoreProveOptions
    <$> strOption
        (  metavar "SPEC_FILE"
        <> long "prove"
        <> help "Kore source file representing spec to be proven.\
                \Needs --spec-module."
        )
    <*> parseModuleName
            "SPEC_MODULE"
            "spec-module"
            "The name of the main module in the spec to be proven."
    <*> parseGraphSearch
    <*> switch
        ( long "bmc"
        <> help "Whether to use the bounded model checker." )
    <*> optional
        (strOption
            (  long "save-proofs"
            <> help
                "The file in which to save the proven claims \
                \in case the prover fails."
            )
        )
  where
    parseGraphSearch =
        option readGraphSearch
            (  metavar "GRAPH_SEARCH"
            <> long "graph-search"
            <> value BreadthFirst
            <> help "Search order of the execution graph. \
                    \Either breadth-first or depth-first. \
                    \Default is breadth-first."
            )
      where
        searchOrders =
            [ ("breadth-first", BreadthFirst)
            , ("depth-first", DepthFirst)
            ]
        readGraphSearch = do
            input <- str
            let found = lookup input searchOrders
            case found of
                Just searchOrder -> pure searchOrder
                Nothing ->
                    let
                        unknown = "Unknown search order '" ++ input ++ "'. "
                        names = intercalate ", " (fst <$> searchOrders)
                        known = "Known search order are: " ++ names
                    in
                        readerError (unknown ++ known)

data KoreMergeOptions =
    KoreMergeOptions
        { rulesFileName     :: !FilePath
        -- ^ Name for file containing a sequence of rules to merge.
        , maybeBatchSize    :: Maybe Int
        }

parseKoreMergeOptions :: Parser KoreMergeOptions
parseKoreMergeOptions =
    KoreMergeOptions
    <$> strOption
        (  metavar "MERGE_RULES_FILE"
        <> long "merge-rules"
        <> help
            "List of rules to merge."
        )
    <*> optional
        (option
            (maybeReader readMaybe)
            (  metavar "MERGE_BATCH_SIZE"
            <> long "merge-batch-size"
            <> help
                "The size of a merge batch."
            )
        )

{- | Record Type containing common command-line arguments for each executable in
the project -}
data GlobalOptions = GlobalOptions
    { willVersion    :: !Bool -- ^ Version flag [default=false]
    }


-- | Record type to store all state and options for the subMain operations
data MainOptions a = MainOptions
    { globalOptions :: !GlobalOptions
    , localOptions  :: !(Maybe a)
    }


{- |
Global main function parses command line arguments, handles global flags
and returns the parsed options
-}
mainGlobal
    :: ExeName
    -> Parser options                -- ^ local options parser
    -> InfoMod (MainOptions options) -- ^ option parser information
    -> IO      (MainOptions options)
mainGlobal exeName localOptionsParser modifiers = do
    options <- commandLineParse exeName localOptionsParser modifiers
    when (willVersion $ globalOptions options) (getZonedTime >>= mainVersion)
    return options

defaultMainGlobal :: IO (MainOptions options)
defaultMainGlobal =
    mainGlobal (ExeName "kore-exec") (argument disabled mempty) mempty


-- | main function to print version information
mainVersion :: ZonedTime -> IO ()
mainVersion time =
      mapM_ putStrLn
      [ "Kore version "    ++ packageVersion
      , "Git:"
      , "  revision:\t"    ++ $gitHash
      , "  branch:\t"      ++ $gitBranch
      , "  last commit:\t" ++  gitTime
      , "Build date:\t"    ++  exeTime
      ]
    where
      packageVersion = showVersion MetaData.version
      formatGit (_:mm:dd:tt:yy:tz:_) = [yy,mm,dd,tt,tz]
      formatGit t                    = t
      gitTime = (unwords . formatGit . words) $gitCommitDate
      exeTime = formatTime defaultTimeLocale  "%Y %b %d %X %z" time


--------------------
-- Option Parsers --

-- | Global Main argument parser for common options
globalCommandLineParser :: Parser GlobalOptions
globalCommandLineParser =
    GlobalOptions
    <$> flag False True
        (  long "version"
        <> help "Print version information" )

-- | Run argument parser for local executable
commandLineParse
    :: ExeName
    -> Parser a                -- ^ local options parser
    -> InfoMod (MainOptions a) -- ^ local parser info modifiers
    -> IO (MainOptions a)
commandLineParse (ExeName exeName) localCommandLineParser modifiers = do
    args' <- Env.getArgs
    env <- Env.lookupEnv "KORE_EXEC_OPTS"
    let opts' = fromMaybe "" env
        args = case env of
            Nothing -> args'
            Just opts -> args' <> words opts
        parseResult = execParserPure
            defaultPrefs
            ( info
                ( MainOptions
                    <$> globalCommandLineParser
                    <*> optional localCommandLineParser
                <**> helper
                )
                modifiers
            )
            args
        changeHelpOverFailure
          | exeName == "kore-exec" = overFailure (changeHelp args opts')
          | otherwise = id
    handleParseResult $ changeHelpOverFailure parseResult
  where
    changeHelp :: [String] -> String -> ParserHelp -> ParserHelp
    changeHelp commandLine koreExecOpts parserHelp@ParserHelp { helpError } =
        parserHelp
            { helpError =
                vsepChunks [Chunk . Just $ commandWithOpts, helpError]
            }
      where
        commandWithOpts =
            Pretty.vsep
                [ Pretty.linebreak
                , Pretty.pretty ("kore-exec " <> unwords commandLine)
                , Pretty.pretty ("KORE_EXEC_OPTS = " <> koreExecOpts)
                ]




----------------------
-- Helper Functions --

{-|
Parser builder to create an optional boolean flag,
with an enabled, disabled and default value.
Based on `enableDisableFlagNoDefault`
from commercialhaskell/stack:
https://github.com/commercialhaskell/stack/blob/master/src/Options/Applicative/Builder/Extra.hs
-}
enableDisableFlag
    :: String -- ^ flag name
    -> option -- ^ enabled value
    -> option -- ^ disabled value
    -> option -- ^ default value
    -> String -- ^ Help text suffix; appended to "Enable/disable "
    -> Parser option
enableDisableFlag name enabledVal disabledVal defaultVal helpSuffix =
    flag' enabledVal
        (  hidden
        <> internal
        <> long name
        <> help helpSuffix)
    <|> flag' disabledVal
        (  hidden
        <> internal
        <> long ("no-" ++ name)
        <> help helpSuffix )
    <|> flag' disabledVal
        (  long ( "[no-]" ++ name )
        <> help ( "Enable/disable " ++ helpSuffix ) )
    <|> pure defaultVal


-- | Time a pure computation and print results.
clockSomething :: String -> a -> Main a
clockSomething description something =
    clockSomethingIO description (liftIO $ evaluate something)


-- | Time an IO computation and print results.
clockSomethingIO :: String -> Main a -> Main a
clockSomethingIO description something = do
    start  <- lift $ getTime Monotonic
    x      <- something
    end    <- lift $ getTime Monotonic
    logEntry $ logMessage end start
    return x
  where
    logMessage end start =
        mkMessage start end
    mkMessage start end =
        Log.LogMessage
            { message =
                pack $ description ++" "++ show (diffTimeSpec end start)
            , severity = Log.Info
            , callstack = emptyCallStack
            }

-- | Verify that a Kore pattern is well-formed and print timing information.
mainPatternVerify
    :: VerifiedModule Attribute.Symbol
    -- ^ Module containing definitions visible in the pattern
    -> ParsedPattern -- ^ Parsed pattern to check well-formedness
    -> Main Verified.Pattern
mainPatternVerify verifiedModule patt = do
    verifyResult <-
        clockSomething "Verifying the pattern"
            (runPatternVerifier context $ verifyStandalonePattern Nothing patt)
    either (error . printError) return verifyResult
  where
    context =
        PatternVerifier.verifiedModuleContext verifiedModule
        & PatternVerifier.withBuiltinVerifiers Builtin.koreVerifiers

lookupMainModule
    :: Monad monad
    => ModuleName
    -> Map.Map
        ModuleName
        (VerifiedModule Attribute.Symbol)
    -> monad (VerifiedModule Attribute.Symbol)
lookupMainModule name modules =
    case Map.lookup name modules of
        Nothing ->
            error
                (  "The main module, '"
                ++ getModuleNameForError name
                ++ "', was not found. Check the --module flag."
                )
        Just m -> return m

{- | Verify the well-formedness of a Kore definition.

Also prints timing information; see 'mainParse'.

 -}
verifyDefinitionWithBase
    ::  ( Map.Map ModuleName (VerifiedModule Attribute.Symbol)
        , Map.Map Text AstLocation
        )
    -- ^ already verified definition
    -> ParsedDefinition
    -- ^ Parsed definition to check well-formedness
    -> Main
        ( Map.Map ModuleName (VerifiedModule Attribute.Symbol)
        , Map.Map Text AstLocation
        )
verifyDefinitionWithBase
    alreadyVerified
    definition
  = do
    verifyResult <- clockSomething "Verifying the definition"
        (verifyAndIndexDefinitionWithBase
            alreadyVerified
            Builtin.koreVerifiers
            definition
        )
    case verifyResult of
        Left err1               -> error (printError err1)
        Right indexedDefinition -> return indexedDefinition

{- | Parse a Kore definition from a filename.

Also prints timing information; see 'mainParse'.

 -}
parseDefinition :: FilePath -> Main ParsedDefinition
parseDefinition = mainParse parseKoreDefinition

mainParse
    :: (FilePath -> String -> Either String a)
    -> String
    -> Main a
mainParse parser fileName = do
    contents <-
        clockSomethingIO "Reading the input file" $ liftIO $ readFile fileName
    parseResult <-
        clockSomething "Parsing the file" (parser fileName contents)
    case parseResult of
        Left err         -> error err
        Right definition -> return definition

type LoadedModule = VerifiedModule Attribute.Symbol

type LoadedDefinition = (Map ModuleName LoadedModule, Map Text AstLocation)

loadDefinitions :: [FilePath] -> Main LoadedDefinition
loadDefinitions filePaths =
    Monad.foldM verifyDefinitionWithBase mempty
    =<< traverse parseDefinition filePaths

loadModule :: ModuleName -> LoadedDefinition -> Main LoadedModule
loadModule moduleName = lookupMainModule moduleName . fst
