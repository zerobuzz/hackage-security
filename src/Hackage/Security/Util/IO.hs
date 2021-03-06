module Hackage.Security.Util.IO (
    withSystemTempFile
  , getFileSize
  , handleDoesNotExist
  ) where

import Control.Exception
import Control.Monad
import System.Directory
import System.IO
import System.IO.Error

withSystemTempFile :: String -> (FilePath -> Handle -> IO a) -> IO a
withSystemTempFile template callback = do
    tmpDir <- getTemporaryDirectory
    bracket (openTempFile tmpDir template) closeAndDelete (uncurry callback)
  where
    closeAndDelete :: (FilePath, Handle) -> IO ()
    closeAndDelete (fp, h) = do
      hClose h
      void $ handleDoesNotExist $ removeFile fp

getFileSize :: FilePath -> IO Integer
getFileSize fp = withFile fp ReadMode hFileSize

handleDoesNotExist :: IO a -> IO (Maybe a)
handleDoesNotExist act =
   handle aux (Just <$> act)
  where
    aux e =
      if isDoesNotExistError e
        then return Nothing
        else throwIO e
