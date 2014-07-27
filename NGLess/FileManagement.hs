module FileManagement
    ( 
        createDir,
        getTempFilePath,
        copyFile,
        getFilesInDir,
        getTFilePathComp,
        getTemporaryDirectory,
        setupRequiredFiles,
        openKFileHandles,
        closekFileHandles,
        doesDirContainFormats,
        printNglessLn,
        generateDirId,
        setupHtmlViewer,
        doesFileExist,
        createDirIfNotExists,
        readPossiblyCompressedFile,
        unCompress,
        writeGZIP,
        write,
        parseFileName,
        template
    ) where

import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B

import qualified Codec.Compression.GZip as GZip    

import qualified Data.Text as T

import System.FilePath.Posix
import System.Directory
import System.IO

import Control.Monad

import System.Posix.Internals (c_getpid)

import System.Console.CmdArgs.Verbosity
import Data.DefaultValues

-- Open and close file handles
openKFileHandles :: Int -> FilePath -> IO [Handle]
openKFileHandles k dest = do
    forM [0..k - 1] $ \x -> do
        openFile (dest </> (show x)) AppendMode

closekFileHandles :: [Handle] -> IO ()
closekFileHandles fhs = mapM_ (hClose) fhs
------------------------------------------

isDot :: FilePath -> Bool
isDot f = f `elem` [".", ".."]

---- Files in a Directory
getFilesInDir :: FilePath -> IO [FilePath]
getFilesInDir p = do
 files <- getDirectoryContents p
 return $ map ((</>) p) (filter (not . isDot) files)

setupRequiredFiles :: FilePath -> FilePath -> IO FilePath
setupRequiredFiles info dirTemplate = do
    let destDir' = dirTemplate ++ "$" ++ info
    htmlSourceP <- htmlDefaultDir
    createDirectory destDir'
    copyFile (htmlSourceP </> "perBaseQualScores.css") (destDir' </> "perBaseQualScores.css")
    copyFile (htmlSourceP </> "perBaseQualityScores.js") (destDir' </> "perBaseQualityScores.js")
    case info of
        "beforeQC" -> copyFile (htmlSourceP </> "beforeQC.html") (destDir' </> "index.html")
        "afterQC" -> copyFile (htmlSourceP </> "afterQC.html") (destDir' </> "index.html")
        err -> error ("Has to be either before or after QC. it is: " ++ (show err))
    return destDir'

-- 
generateTempFilePath :: FilePath -> String -> IO FilePath
generateTempFilePath dst t = do
    (f,s) <- openTempFile dst t   
    hClose s   
    return f

--Example: "folders/sample_1.9168$afterQC" @?= ("folders/","sample_1")
parseFileName :: FilePath -> (FilePath, FilePath)
parseFileName = splitFileName . fst . break ((==) '$') . fst . splitExtensions

getTempFilePath :: FilePath -> IO FilePath
getTempFilePath fp = do
    let (dst, t) = parseFileName fp
    generateTempFilePath dst t
    
getTFilePathComp :: FilePath -> IO FilePath
getTFilePathComp fp = do
    let (dst, t) = parseFileName fp
    generateTempFilePath dst (t <.> "gz")

---- generate template from path
template :: FilePath -> FilePath
template = snd . splitFileName . fst . splitExtensions
    
createDir :: FilePath -> IO FilePath
createDir dst = do
    fp <- getTemporaryDirectory >>= flip createTempDirectory (template dst)
    createDirectory fp
    return fp

generateDirId :: FilePath -> IO FilePath
generateDirId dst = defaultDir >>= flip createTempDirectory (template dst) >>= return
    
createDirIfNotExists :: FilePath -> IO ()
createDirIfNotExists dst =  doesDirectoryExist dst >>= \x -> when (not x) $ createDirectory dst


createTempDirectory :: FilePath -> String -> IO FilePath
createTempDirectory dir t = do
  pid <- c_getpid
  fp <- findTempName pid
  return fp
  where
    findTempName x = do
      let dirpath = dir </> t <.> show x
      r <- doesDirectoryExist (dirpath ++ "$beforeQC")
      case r of
        False  -> return dirpath
        True -> findTempName (x+1)

doesDirContainFormats :: String -> [String] -> IO Bool
doesDirContainFormats _ [] = return True
doesDirContainFormats path (x:xs) = do 
    x' <- doesFileExist (path ++ x)
    case x' of 
        True -> doesDirContainFormats path xs
        False -> return False

printNglessLn :: String -> IO ()
printNglessLn x = whenLoud $ putStrLn x 

setupHtmlViewer :: IO ()
setupHtmlViewer = do
    htmlP <- htmlDefaultDir
    dst <- defaultDir
    doesFileExist (p' dst) >>= \x -> case x of 
        True   -> return ()
        False  -> copyDir htmlP dst
    where p' = (</> "nglessKeeper.html")

copyDir ::  FilePath -> FilePath -> IO ()
copyDir src dst = do
  createDirIfNotExists dst
  xs <- getDirectoryContents src >>= return . filter (not . isDot)
  forM_ xs $ \n -> do
    x <- doesDirectoryExist (src </> n)
    case x of 
        True  -> copyDir (src </> n) (dst </> n)
        False -> copyFile (src </> n) (dst </> n)



writeGZIP :: String -> BL.ByteString -> IO ()
writeGZIP fp contents = BL.writeFile fp $ GZip.compress contents 

write :: String -> BL.ByteString -> IO ()
write fp contents = BL.writeFile fp contents 


-------- read files
unCompress :: FilePath -> IO BL.ByteString
unCompress fname =
    if T.isInfixOf (T.pack ".gz") (T.pack fname)
        then fmap GZip.decompress (BL.readFile fname)
        else BL.readFile fname -- not compressed

readPossiblyCompressedFile ::  B.ByteString -> IO BL.ByteString
readPossiblyCompressedFile fileName = unCompress (B.unpack fileName)
-----------
