{- Copyright 2015-2018 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE RecordWildCards, FlexibleContexts, MultiWayIf #-}

module ExternalModules
    ( loadModule
    ) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.List.Utils as LU
import qualified Data.Conduit as C
import qualified Data.Conduit.Combinators as CC
import           Data.Conduit ((.|))
import           Control.Monad.Extra (whenJust)
import           GHC.Conc (getNumCapabilities)
import           Data.Yaml ((.!=), (.:?), (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Yaml as Yaml

import Control.Applicative
import Control.Monad
import System.Process
import System.Environment (getEnvironment, getExecutablePath)
import System.Directory (getDirectoryContents, doesFileExist, doesDirectoryExist, canonicalizePath)
import System.Exit
import System.IO
import System.FilePath
import Data.Maybe
import Data.List (find, isSuffixOf)
import Data.Default (def)

import Data.FastQ.Utils (concatenateFQs)
import Data.FastQ
import NGLess.NGLEnvironment
import FileManagement
import Utils.Samtools
import Configuration
import Utils.Conduit
import FileOrStream
import Utils.Suggestion
import Utils.Utils
import Utils.LockFile (LockParameters(..), WhenExistsStrategy(IfLockedRetry, timeBetweenRetries, nrLockRetries), withLockFile)
import Utils.Network (downloadExpandTar)
import Language
import Modules
import Output
import NGLess


downloadableModules = -- Should this be merged with knownModules?
    [("example-cmd", "0.0")
    ,("motus", "0.0")
    ,("motus", "0.1")
    ,("specI", "0.0")
    ,("specI", "0.1")
    ,("igc", "0.0")
    ,("igc", "0.5")
    ,("om-rgc", "0.0")
    ]


-- | Basic file types
data FileTypeBase =
    FastqFileSingle
    | FastqFilePair
    | FastqFileTriplet
    | SamFile
    | BamFile
    | SamOrBamFile
    | TSVFile
    deriving (Eq,Show)

instance Aeson.FromJSON FileTypeBase where
    parseJSON = Aeson.withText "filetypebase" $ \case
        "fq1" -> return FastqFileSingle
        "fq2" -> return FastqFilePair
        "fq3" -> return FastqFileTriplet
        "sam" -> return SamFile
        "bam" -> return BamFile
        "sam_or_bam" -> return SamOrBamFile
        "tsv" -> return TSVFile
        ft -> fail ("unknown file type '"++T.unpack ft++"'")

data FileType = FileType
    { _fileTypeBase :: !FileTypeBase
    , _canGzip :: !Bool
    , _canBzip2 :: !Bool
    , _canStream :: !Bool
    } deriving (Eq, Show)

instance Aeson.FromJSON FileType where
    parseJSON = Aeson.withObject "filetype" $ \o ->
        FileType
            <$> o .: "filetype"
            <*> o .:? "can_gzip" .!= False
            <*> o .:? "can_bzip2" .!= False
            <*> o .:? "can_stream" .!= False

data CommandExtra = FlagInfo [T.Text]
            | FileInfo FileType
            deriving (Eq, Show)

data CommandArgument = CommandArgument
        { cargInfo :: ArgInformation
        , cargDef :: Maybe NGLessObject -- ^ default value
        , cargPayload :: Maybe CommandExtra
        }
    deriving (Eq, Show)

instance Aeson.FromJSON CommandArgument where
    parseJSON = Aeson.withObject "command argument" $ \o -> do
        argName <- o .:? "name" .!= ""
        argRequired <- o .:? "required" .!= False
        atype <- o .: "atype"
        (argType, cargDef) <- case atype of
            "flag" -> do
                defVal <- o .:? "def"
                return (NGLBool, NGOBool <$> defVal)
            "option" -> do
                defVal <- o .:? "def"
                return (NGLSymbol, NGOSymbol <$> defVal)
            "int" -> do
                defVal <- o .:? "def"
                return (NGLInteger, NGOInteger <$> defVal)
            "str" -> do
                defVal <- o .:? "def"
                return (NGLString, NGOString <$> defVal)
            "readset" -> return (NGLReadSet, Nothing)
            "counts" -> return (NGLCounts, Nothing)
            "mappedreadset" -> return (NGLMappedReadSet, Nothing)
            _ -> fail ("unknown argument type "++atype)
        argChecks <- if atype == "option"
                then do
                    allowed <- o .: "allowed"
                    return [ArgCheckSymbol allowed]
                else return []
        let cargInfo = ArgInformation{..}
        cargPayload <-
            if
                | atype `elem` ["option", "flag"] -> liftM FlagInfo <$> ((Just . (:[]) <$> o .: "when-true") <|> o .:? "when-true")
                | atype `elem` ["readset", "counts", "mappedreadset"] -> (Just . FileInfo <$> Aeson.parseJSON (Aeson.Object o)) <|> return Nothing
                | otherwise -> return Nothing
        return CommandArgument{..}

newtype ReadNGLType = ReadNGLType { unwrapReadNGLType :: NGLType }

instance Aeson.FromJSON ReadNGLType where
    parseJSON = Aeson.withText "ngltype" $ \rtype -> do
        ReadNGLType <$> case rtype of
            "void" -> return NGLVoid
            "counts" -> return NGLCounts
            "readset" -> return NGLReadSet
            "mappedreadset" -> return NGLMappedReadSet
            other -> fail ("Cannot parse unknown type '"++T.unpack other++"'")

data CommandReturn = CommandReturn
                        { commandReturnType :: !NGLType
                        , _commandReturnName :: !T.Text
                        , _commandReturnExt :: FilePath
                        }
    deriving (Eq, Show)

instance Aeson.FromJSON CommandReturn where
    parseJSON = Aeson.withObject "hidden argument" $ \o -> do
        t <- unwrapReadNGLType <$> o .: "rtype"
        if t == NGLVoid
            then return $! CommandReturn NGLVoid "" ""
            else CommandReturn t <$> o .: "name" <*> o .: "extension"

data Command = Command
    { nglName :: T.Text         -- ^ what function is called inside ngless
    , arg0 :: FilePath          -- ^ what the script is
    , arg1 :: CommandArgument   -- ^ all ngless functions take an argument
    , additional :: [CommandArgument]
    , ret :: CommandReturn
    } deriving (Eq, Show)

instance Aeson.FromJSON Command where
    parseJSON = Aeson.withObject "function" $ \o ->
        Command
            <$> o .: "nglName"
            <*> o .: "arg0"
            <*> o .: "arg1"
            <*> o .:? "additional" .!= []
            <*> o .:? "return" .!=  CommandReturn NGLVoid "" ""

data ExternalModule = ExternalModule
    { emInfo :: ModInfo -- ^ module information
    , modulePath :: FilePath -- ^ directory where module files are located
    , initCmd :: Maybe FilePath
    , initArgs :: [String]
    , emFunctions :: [Command]
    , references :: [ExternalReference]
    , emCitations :: [T.Text]
    } deriving (Eq, Show)

instance Aeson.FromJSON ExternalModule where
    parseJSON = Aeson.withObject "module" $ \o -> do
        initO <- o .:? "init"
        (initCmd, initArgs) <- case initO of
            Nothing -> return (Nothing, [])
            Just initO' -> do
                init_cmd <- initO' .: "init_cmd"
                init_args <- initO' .:? "init_args" .!= []
                return (init_cmd, init_args)
        references <- o .:? "references" .!= []
        emFunctions <- o .:? "functions" .!= []
        singleCitation <- o .:? "citation"
        citations <- o .:? "citations" .!= []
        let emCitations = maybeToList singleCitation ++ citations
        emInfo <- ModInfo <$> o .: "name" <*> o .: "version"
        let modulePath = undefined
        return ExternalModule{..}

addPathToRep :: FilePath -> ExternalModule -> ExternalModule
addPathToRep mpath m = m { modulePath = mpath, references = map (addPathToRef mpath) (references m) }

addPathToRef :: FilePath -> ExternalReference -> ExternalReference
addPathToRef mpath er@ExternalReference{..} = er
        { faFile = ma faFile
        , gtfFile = ma <$> gtfFile
        , geneMapFile = ma <$> geneMapFile
        }
    where
        ma p
            | isAbsolute p = p
            | otherwise = mpath </> p
addPathToRef _ er = er


asFunction Command{..} = Function (FuncName nglName) (Just . argType . cargInfo $ arg1) [] (commandReturnType ret) (map cargInfo additional) False []

{- | Environment to expose to module processes -}
nglessEnv :: FilePath -> NGLessIO [(String,String)]
nglessEnv basedir = do
    tmpdir <- nConfTemporaryDirectory <$> nglConfiguration
    liftIO $ do
        env <- getEnvironment
        let env' = filter ((`notElem` ["TMP", "TMPDIR", "TEMP", "TEMPDIR"]) . fst) env
        ncpu <- getNumCapabilities
        nglessPath <- getExecutablePath
        return $ ("NGLESS_NGLESS_BIN", nglessPath)
                :("NGLESS_MODULE_DIR", basedir)
                :("NGLESS_NR_CORES", show ncpu)
                :("TMPDIR", tmpdir) -- TMPDIR is the POSIX standard
                :("TMP", tmpdir) -- TMP is also used on Windows
                :("TEMPDIR", tmpdir) -- Some software uses TEMP/TEMPDIR
                :("TEMP", tmpdir)
                :env'

executeCommand :: FilePath -> [Command] -> T.Text -> NGLessObject -> KwArgsValues -> NGLessIO NGLessObject
executeCommand basedir cmds funcname input args = do
    cmd <- maybe
                (throwShouldNotOccur ("Call to undefined function "++T.unpack funcname++"."))
                return
                (find ((== funcname) . nglName) cmds)
    paths <- encodeArgument (arg1 cmd) (Just input)
    paths' <- liftIO $ mapM canonicalizePath paths
    args' <- argsArguments cmd args
    moarg <- case ret cmd of
        CommandReturn NGLVoid _ _ -> return Nothing
        CommandReturn _ name ext -> do
            (newfp, hout) <- openNGLTempFile "external" "eout_" ext
            liftIO $ hClose hout
            let oarg = "--"++T.unpack name++"="++newfp
            return $ Just (newfp, [oarg])
    env <- nglessEnv basedir
    let cmdline = paths' ++ args' ++ maybe [] snd moarg
        process = (proc (basedir </> arg0 cmd) cmdline) { env = Just env }
    outputListLno' TraceOutput ["executing command: ", arg0 cmd, " ", LU.join " " cmdline]
    (exitCode, out, err) <- liftIO $
        readCreateProcessWithExitCode process ""
    outputListLno' TraceOutput ["Processing results: (STDOUT=", out, ", STDERR=", err,") with exitCode: ", show exitCode]
    case (exitCode,out,err) of
        (ExitSuccess, "", "") -> return ()
        (ExitSuccess, msg, "") -> outputListLno' TraceOutput ["Module OK. information: ", msg]
        (ExitSuccess, mout, merr) -> outputListLno' TraceOutput ["Module OK. information: ", mout, ". Warning: ", merr]
        (ExitFailure code, _,_) ->
            throwSystemError .concat $ ["Error running command for function ", show funcname, "\n",
                "\texit code = ", show code,"\n",
                "\tstdout='", out, "'\n",
                "\tstderr='", err, "'"]
    let groupName (NGOMappedReadSet g _ _) = g
        groupName (NGOReadSet g _) = g
        groupName _ = ""
    case moarg of
        Nothing -> return NGOVoid
        Just (newfp, _) -> case commandReturnType $ ret cmd of
            NGLCounts -> return $ NGOCounts (File newfp)
            NGLMappedReadSet -> return $ NGOMappedReadSet (groupName input) (File newfp) Nothing
            ret -> throwShouldNotOccur ("Not implemented (ExternalModules.hs:executeCommand commandReturnType = "++show ret++")")

asFilePaths :: NGLessObject -> Maybe CommandExtra -> NGLessIO  [FilePath]
asFilePaths (NGOReadSet _ (ReadSet paired singles)) _ = do
    let concatenateFQs' [] = return Nothing
        concatenateFQs' rs = Just <$> concatenateFQs rs
    fq1 <- concatenateFQs' (fst <$> paired)
    fq2 <- concatenateFQs' (snd <$> paired)
    fq3 <- concatenateFQs' singles
    case (fq1, fq2, fq3) of
        (Nothing, Nothing, Just f)  -> return [fqpathFilePath f]
        (Just f1, Just f2, Nothing) -> return [fqpathFilePath f1, fqpathFilePath f2]
        (Just f1, Just f2, Just f3) -> return [fqpathFilePath f1, fqpathFilePath f2, fqpathFilePath f3]
        _ -> throwScriptError "Malformed input argument to asFilePaths"
asFilePaths input@(NGOCounts _) argOptions = (:[]) <$> asCountsFile input argOptions
asFilePaths (NGOMappedReadSet _ input _) payload = (:[]) <$> do
    filepath <- asFile input
    case payload of
        Nothing -> return filepath
        Just (FileInfo (FileType fb gz bz2 _)) -> case fb of
            SamFile -> asSamFile filepath gz bz2
            BamFile -> asBamFile filepath
            SamOrBamFile -> return filepath
            _ -> throwScriptError "Unexpected combination of arguments"
        Just other -> throwShouldNotOccur ("encodeArgument: unexpected payload: "++show other)
asFilePaths invalid _ = throwShouldNotOccur ("AsFile path got "++show invalid)

asCountsFile :: NGLessObject -> Maybe CommandExtra -> NGLessIO String
asCountsFile (NGOCounts icounts) Nothing = asFile icounts
asCountsFile (NGOCounts icounts) (Just (FileInfo (FileType _ gz bz2 _))) = do
    icounts' <- asFile icounts
    let igz = ".gz" `isSuffixOf` icounts'
        ibz2 = ".bz2" `isSuffixOf` icounts'
    if (igz && not gz) || (ibz2 && not bz2)
        then uncompressFile icounts'
        else return icounts'
asCountsFile v a = throwScriptError ("Expected counts for argument in function call, got " ++ show v ++ ". " ++ show a)

-- Encodes the argument for the command line, performing any necessary
-- transforms (e.g., unzipping).
--
-- The code is not as complex as it seems, but there are a lot of special cases.
encodeArgument :: CommandArgument -> Maybe NGLessObject -> NGLessIO [String]
encodeArgument (CommandArgument ai Nothing _) Nothing
    | not (argRequired ai) = return []
    | otherwise = throwScriptError $ concat ["Missing value for required argument ", T.unpack (argName ai), "."]
encodeArgument ca@(CommandArgument _ v _) Nothing = encodeArgument ca v
encodeArgument (CommandArgument ai _ payload) (Just v)
    | argType ai == NGLBool = do
        val <- boolOrTypeError "in command module" v
        return $! if not val
            then []
            else case payload of
                Just (FlagInfo flags) -> map T.unpack flags
                _ -> ["--" ++ T.unpack (argName ai)]
    | argType ai == NGLReadSet = case v of
        NGOReadSet{} -> asFilePaths v undefined
        _ -> throwScriptError ("Expected readset for argument in function call, got " ++ show v)
    | otherwise = do
        asStr <- case argType ai of
            NGLString -> do
                str <- T.unpack <$> stringOrTypeError "in external module" v
                fromMaybe str <$> expandPath str
            NGLSymbol -> T.unpack <$> symbolOrTypeError "in external module" v
            NGLInteger ->  show <$> integerOrTypeError "in external module" v
            NGLMappedReadSet -> case v of
                NGOMappedReadSet{} -> head <$> asFilePaths v payload
                _ -> throwScriptError ("Expected mappedreadset for argument in function call, got " ++ show v)
            NGLCounts -> asCountsFile v payload
            other -> throwShouldNotOccur ("Unexpected type tag in external module " ++ show other)
        return $! if argName ai == ""
                    then [asStr]
                    else [concat ["--", T.unpack (argName ai), "=", asStr]]

-- As (possibly compressed) sam file
asSamFile fname gz bz2
    | ".sam" `isSuffixOf` fname = return fname
    | ".sam.gz" `isSuffixOf` fname = if gz
        then return fname
        else uncompressFile fname
    | ".sam.bz2" `isSuffixOf` fname = if bz2
        then return fname
        else uncompressFile fname
    | ".bam" `isSuffixOf` fname = convertBamToSam fname
    | otherwise = return fname

asBamFile fname
    | ".bam" `isSuffixOf` fname = return fname
    | ".sam" `isSuffixOf` fname = convertSamToBam fname
    | otherwise = return fname

uncompressFile :: FilePath -> NGLessIO FilePath
uncompressFile f = makeNGLTempFile f "uncompress_" (takeBaseName f) $ \hout ->
        C.runConduit $
            conduitPossiblyCompressedFile f
                .| CC.sinkHandle hout

argsArguments :: Command -> KwArgsValues -> NGLessIO [String]
argsArguments cmd args = concat <$> forM (additional cmd) a1
    where
        a1 ci@(CommandArgument ai _ _) = encodeArgument ci (lookup (argName ai) args)

asInternalModule :: ExternalModule -> NGLessIO Module
asInternalModule em@ExternalModule{..} = do
    validateModule em
    return def
        { modInfo = emInfo
        , modCitations = emCitations
        , modReferences = references
        , modFunctions = map asFunction emFunctions
        , runFunction = executeCommand modulePath emFunctions
        }

-- | performs internal validation and calls init-cmd (if any)
validateModule :: ExternalModule -> NGLessIO ()
validateModule  em@ExternalModule{..} = do
    checkSyntax em
    withLockFile LockParameters
        { lockFname = modulePath ++ ".ngless-init.lock"
        , maxAge = hoursToDiffTime 24  -- init can compile/install stuff.
        , whenExistsStrategy = IfLockedRetry { nrLockRetries = 37*60, timeBetweenRetries = 60 }
        } $ do
            whenJust initCmd $ \initCmd' -> do
                outputListLno' DebugOutput ("Running initialization for module ":show emInfo:" ":initCmd':" ":initArgs)
                env <- nglessEnv modulePath
                (exitCode, out, err) <- liftIO $
                    readCreateProcessWithExitCode (proc (modulePath </> initCmd') initArgs) { env = Just env } ""
                case (exitCode,out,err) of
                    (ExitSuccess, "", "") -> return ()
                    (ExitSuccess, msg, "") -> outputListLno' TraceOutput ["Module OK. information: ", msg]
                    (ExitSuccess, mout, merr) -> outputListLno' TraceOutput ["Module OK. information: ", mout, ". Warning: ", merr]
                    (ExitFailure code, _,_) -> do
                        outputListLno' WarningOutput ["Module loading failed for module ", show emInfo]
                        throwSystemError .concat $ ["Error loading module ", show emInfo, "\n",
                            "When running the validation command (", initCmd', " with arguments ", show initArgs, ")\n",
                            "\texit code = ", show code,"\n",
                            "\tstdout='", out, "'\n",
                            "\tstderr='", err, "'"]
        where
            hoursToDiffTime h = fromInteger (h * 3600)


-- | Attempts to find bugs in its argument. When no errors are found, it does
-- nothing
checkSyntax :: ExternalModule -> NGLessIO ()
checkSyntax ExternalModule{..} = forM_ emFunctions $ \f -> do
        checkArg1NoName f
        checkArgsTypes (arg1 f)
        forM_ (additional f) $ \a -> do
            checkArgsAllNamed1 a
            checkArgsTypes a
    where
        checkArg1NoName :: Command -> NGLessIO ()
        checkArg1NoName Command{..} =
            when ((argName . cargInfo $ arg1) /= "") $
                throwScriptError "Error in module.yaml: `arg1` cannot have a 'name' attribute"
        checkArgsAllNamed1 :: CommandArgument -> NGLessIO ()
        checkArgsAllNamed1 (CommandArgument ai _ _) =
            when (argName ai == "") $
                throwScriptError "Error in module.yaml: `additional` argument is missing a name"
        checkArgsTypes :: CommandArgument -> NGLessIO ()
        checkArgsTypes (CommandArgument ai _ (Just (FileInfo (FileType ft _ _ _)))) = do
                let atype = argType ai
                when ((atype, ft) `notElem` legalNGLTypeFileTypeCombos) $
                    throwScriptError "Illegal combination of options for atype/filetype"
        checkArgsTypes _ = return ()

        legalNGLTypeFileTypeCombos = [
                (NGLReadSet, FastqFileSingle)
                ,(NGLReadSet, FastqFilePair)
                ,(NGLReadSet, FastqFileTriplet)
                ,(NGLMappedReadSet, SamFile)
                ,(NGLMappedReadSet, BamFile)
                ,(NGLMappedReadSet, SamOrBamFile)
                ,(NGLCounts, TSVFile)
                ]


findFirstM :: (Monad m) => (a -> m (Maybe b)) -> [a] -> m (Maybe b)
findFirstM _ [] = return Nothing
findFirstM f (x:xs) = f x >>= \case
    Nothing -> findFirstM f xs
    other -> return other

downloadModule :: T.Text -> T.Text -> NGLessIO FilePath
downloadModule modname modversion = do
    dataDirectory <- nConfUserDataDirectory <$> nglConfiguration
    baseUrl <- nConfDownloadBaseURL <$> nglConfiguration
    let nameversion = T.unpack modname <.> "ngm" </> T.unpack modversion
        destdir = dataDirectory </> "Modules" </> nameversion
        url = baseUrl </> "Modules" </> nameversion <.> "tar.gz"
    downloadExpandTar url dataDirectory
    return destdir

-- | Find and load the external module
findLoad :: T.Text -> T.Text -> NGLessIO ExternalModule
findLoad modname version = do
    let modpath' = "Modules" </> T.unpack modname <.> "ngm"
        modpath = modpath' </> T.unpack version
        modfile = "module.yaml"
    globalDir <- nConfGlobalDataDirectory <$> nglConfiguration
    userDir <- nConfUserDataDirectory <$> nglConfiguration
    found <- flip findFirstM [".", globalDir, userDir] $ \basedir -> do
        let fname = basedir </> modpath </> modfile
        exists <- liftIO $ doesFileExist fname
        outputListLno' TraceOutput ["Looking for module ", T.unpack modname, " at `", fname, if exists then "` and found it." else "` and did not find it."]
        return $! if exists
            then Just (basedir </> modpath)
            else Nothing
    found' <- case found of
        Nothing
            | (modname, version) `elem` downloadableModules -> Just <$> downloadModule modname version
        _ -> return found
    case found' of
        Just mdir -> Yaml.decodeEither <$> liftIO (B.readFile (mdir </> modfile)) >>= \case
                        Right v -> do
                            checkCompatible modname version (emInfo v)
                            return (addPathToRep mdir v)
                        Left err -> throwSystemError ("Could not load module file "++ mdir </> modfile ++ ". Error was `" ++ err ++ "`")
        Nothing -> do
                others <- forM [".", globalDir, userDir] $ \basedir -> do
                    let dname = basedir </> modpath'
                        listDirectory d = filter (`notElem` [".", ".."]) <$> getDirectoryContents d
                    exists <- liftIO $ doesDirectoryExist dname
                    if not exists
                         then return []
                         else liftIO (listDirectory dname)
                throwSystemError
                    ("Could not find external module '" ++ T.unpack modname ++
                        (case concat others of
                            [] -> "'."
                            foundVersions -> "' version " ++ T.unpack version ++ ".\n"
                                            ++ "Please check the version number. I found the following versions:" ++
                                                concat ["\n\t- " ++ show v | v <- uniq foundVersions]))

checkCompatible :: T.Text -> T.Text -> ModInfo -> NGLessIO ()
checkCompatible modname version mi = do
        let version' = modVersion mi
        nversion <- norm version
        nversion' <- norm version'
        when (nversion' /= nversion) $
            throwSystemError (concat ["Mismatched version information when loading module `", T.unpack modname, "`.\n\t"
                            ,"Expected ", T.unpack version, " but file contains '", T.unpack version', "'."])
    where
        norm ver = case T.split (== '.') ver of
            (majv:minv:_) -> return (majv, minv)
            _ -> throwScriptError ("Cannot parse version string '"++T.unpack ver++"'.")

loadModule :: ModInfo -> NGLessIO Module
loadModule mi
        | isGlobalImport mi && name `notElem` knownModules =
            throwScriptError ("Module '" ++ T.unpack name ++ "' is not known.\n\t" ++ T.unpack (suggestionMessage name knownModules) ++ "\n\tTo import local modules, use \"local import\"")
        | otherwise = asInternalModule =<< findLoad name version
    where
        isGlobalImport LocalModInfo{} = False
        isGlobalImport ModInfo{} = True
        name = modName mi
        version = modVersion mi

