{- Copyright 2013-2016 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE OverloadedStrings #-}

module Interpretation.Write
    ( executeWrite
    , _formatFQOname
    ) where


import Control.Monad
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import System.Process
import System.Exit
import System.IO
import Data.String.Utils
import Data.List (isInfixOf)
import Data.Maybe

import Language
import FileManagement
import Configuration
import NGLess
import Output
import Utils.Utils

removeEnd :: String -> String -> String
removeEnd base suffix = take (length base - length suffix) base

_formatFQOname :: FilePath -> FilePath -> NGLessIO FilePath
_formatFQOname base insert
    | base `isInfixOf` "{index}" = return (replace base "{index}" ("." ++ insert ++ "."))
    | endswith ".fq" base = return $ removeEnd base ".fq" ++ "." ++ insert ++ ".fq"
    | endswith ".fq.gz" base = return $ removeEnd base ".fq" ++ "." ++ insert ++ ".fq.gz"
    | otherwise = throwScriptError ("Cannot handle " ++ base)

getOFile :: KwArgsValues -> NGLessIO FilePath
getOFile args = do
    sub <- nConfSubsample <$> nglConfiguration
    let subpostfix = if sub then ".subsampled" else ""
    case lookup "ofile" args of
        Just (NGOFilename p) -> return (p ++ subpostfix)
        Just (NGOString p) -> return (T.unpack p ++ subpostfix)
        _ -> throwShouldNotOccur ("getOFile cannot decode file path" :: String)

writeToFile :: NGLessObject -> FilePath -> NGLessIO NGLessObject
writeToFile (NGOMappedReadSet name path defGen) newfp = liftIO $ do
    readPossiblyCompressedFile path >>= BL.writeFile newfp
    return $ NGOMappedReadSet name newfp defGen

writeToFile obj _ = throwShouldNotOccur ("writeToFile: Should have received a NGOReadSet or a NGOMappedReadSet but the type was: " ++ show obj)

writeRSToFile enc path newfp = liftIO $
    readPossiblyCompressedFile path >>= BL.writeFile newfp


executeWrite :: NGLessObject -> [(T.Text, NGLessObject)] -> NGLessIO NGLessObject
executeWrite (NGOList el) args = do
    templateFP <- getOFile args
    let args' = filter (\(a,_) -> (a /= "ofile")) args
        fps = map ((\fname -> replace "{index}" fname templateFP) . show) [1..length el]
    res <- zipWithM (\e fp -> executeWrite e (("ofile", NGOFilename fp):args')) el fps
    return (NGOList res)

executeWrite (NGOReadSet rs) args = do
    ofile <- getOFile args
    case rs of
        ReadSet1 enc r -> do
            writeRSToFile enc r ofile
            return (NGOReadSet $ ReadSet1 enc ofile)
        ReadSet2 enc r1 r2 -> do
            fname1 <- _formatFQOname ofile "pair.1"
            fname2 <- _formatFQOname ofile "pair.2"
            writeRSToFile enc r1 fname1
            writeRSToFile enc r2 fname2
            return (NGOReadSet $ ReadSet2 enc fname1 fname2)
        ReadSet3 enc r1 r2 r3 -> do
            fname1 <- _formatFQOname ofile "pair.1"
            fname2 <- _formatFQOname ofile "pair.2"
            fname3 <- _formatFQOname ofile "singles"
            writeRSToFile enc r1 fname1
            writeRSToFile enc r2 fname2
            writeRSToFile enc r3 fname3
            return (NGOReadSet $ ReadSet3 enc fname1 fname2 fname3)


executeWrite el@(NGOMappedReadSet name fp defGen) args = do
    newfp <- getOFile args
    let format = fromMaybe (NGOSymbol "sam") (lookup "format" args)
    case format of
        NGOSymbol "sam" -> writeToFile el newfp
        NGOSymbol "bam" -> do
                        newfp' <- convertSamToBam fp newfp
                        return (NGOMappedReadSet name newfp' defGen) --newfp will contain the bam
        NGOSymbol s -> throwScriptError (T.concat ["write does not accept format {", s, "} with input type ", T.pack . show $ el])
        _ -> throwShouldNotOccur ("Type checking fail: format argument is not a symbol for write()" :: String)

executeWrite (NGOAnnotatedSet name fp headers) args = do
    newfp <- getOFile args
    outputListLno' InfoOutput ["Writing AnnotatedSet to: ", newfp]
    nglMaybeCopyFile fp newfp
    return $ NGOAnnotatedSet name newfp headers

executeWrite (NGOCounts fp) args = do
    newfp <- getOFile args
    outputListLno' InfoOutput ["Writing counts to: ", newfp]
    nglMaybeCopyFile fp newfp
    return $ NGOCounts newfp

executeWrite v _ = throwShouldNotOccur ("Error: executeWrite of " ++ show v ++ " not implemented yet.")

getDelimiter :: NGLessObject -> NGLessIO B.ByteString
getDelimiter (NGOSymbol "csv") = return ","
getDelimiter (NGOSymbol "tsv") = return "\t"
getDelimiter (NGOSymbol f) = throwScriptError ("Invalid format in write: {"++T.unpack f++"}")
getDelimiter v =  throwShouldNotOccur ("Type of 'format' in 'write' must be NGOSymbol, got " ++ show v)

convertSamToBam samfile newfp = do
    outputListLno' DebugOutput ["SAM->BAM Conversion start ('", samfile, "' -> '", newfp, "')"]
    samPath <- samtoolsBin
    (errmsg, exitCode) <- liftIO $ withFile newfp WriteMode $ \hout ->
        readProcessErrorWithExitCode (
                proc samPath
                    ["view", "-bS", samfile]
                ) { std_out = UseHandle hout }
    outputListLno' InfoOutput ["Message from samtools: ", errmsg]
    case exitCode of
       ExitSuccess -> return newfp
       ExitFailure err -> throwSystemError ("Failure on converting sam to bam" ++ show err)
