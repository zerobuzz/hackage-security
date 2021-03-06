-- | An implementation of Repository that talks to repositories over HTTP.
--
-- This implementation is itself parameterized over a 'HttpClient', so that it
-- it not tied to a specific library; for instance, 'HttpClient' can be
-- implemented with the @HTTP@ library, the @http-client@ libary, or others.
--
-- It would also be possible to give _other_ Repository implementations that
-- talk to repositories over HTTP, if you want to make other design decisions
-- than we did here, in particular:
--
-- * We attempt to do incremental downloads of the index when possible.
-- * We reuse the "Repository.Local"  to deal with the local cache.
-- * We download @timestamp.json@ and @snapshot.json@ together. This is
--   implemented here because:
--   - One level down (HttpClient) we have no access to the local cache
--   - One level up (Repository API) would require _all_ Repositories to
--     implement this optimization.
module Hackage.Security.Client.Repository.HTTP (
    -- * Server capabilities
    ServerCapabilities -- opaque
  , newServerCapabilities
  , getServerSupportsAcceptBytes
  , setServerSupportsAcceptBytes
    -- * Abstracting over HTTP libraries
  , BodyReader
  , HttpClient(..)
  , FileSize(..)
  , Cache
    -- ** Utility
  , fileSizeWithinBounds
    -- * Top-level API
  , withRepository
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad.Except
import Network.URI
import System.Directory
import System.FilePath
import System.IO
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BS.L

import Hackage.Security.Client.Formats
import Hackage.Security.Client.Repository
import Hackage.Security.Client.Repository.Local (Cache)
import Hackage.Security.Key.ExplicitSharing
import Hackage.Security.Trusted
import Hackage.Security.TUF
import Hackage.Security.Util.IO
import Hackage.Security.Util.Some
import qualified Hackage.Security.Client.Repository.Local as Local
import qualified Hackage.Security.JSON.Archive            as Archive
import qualified Hackage.Security.Key.Env                 as KeyEnv

{-------------------------------------------------------------------------------
  Server capabilities
-------------------------------------------------------------------------------}

-- | Server capabilities
--
-- As the library interacts with the server and receives replies, we may
-- discover more information about the server's capabilities; for instance,
-- we may discover that it supports incremental downloads.
newtype ServerCapabilities = SC (MVar ServerCapabilities_)

-- | Internal type recording the various server capabilities we support
--
-- This is not exported; we only export functions that work on
-- 'ServerCapabilities'.
data ServerCapabilities_ = ServerCapabilities {
      serverSupportsAcceptBytes :: Bool
    }

newServerCapabilities :: IO ServerCapabilities
newServerCapabilities = SC <$> newMVar ServerCapabilities {
      serverSupportsAcceptBytes = False
    }

setServerSupportsAcceptBytes :: ServerCapabilities -> Bool -> IO ()
setServerSupportsAcceptBytes (SC mv) x = modifyMVar_ mv $ \caps ->
    return $ caps { serverSupportsAcceptBytes = x }

getServerSupportsAcceptBytes :: ServerCapabilities -> IO Bool
getServerSupportsAcceptBytes (SC mv) = withMVar mv $ \caps ->
    return $ serverSupportsAcceptBytes caps

{-------------------------------------------------------------------------------
  Abstraction over HTTP clients (such as HTTP, http-conduit, etc.)
-------------------------------------------------------------------------------}

data FileSize =
    -- | For most files we download we know the exact size beforehand
    -- (because this information comes from the snapshot or delegated info)
    FileSizeExact Int

    -- | For some files we might not know the size beforehand, but we might
    -- be able to provide an upper bound (timestamp, root info)
  | FileSizeBound Int

    -- | If we don't want to guess, we can also just indicate we have no idea
    -- what size file we are expecting. This means we cannot protect against
    -- endless data attacks however.
    --
    -- TODO: Once we put in estimates we should get rid of this.
  | FileSizeUnknown

fileSizeWithinBounds :: Int -> FileSize -> Bool
fileSizeWithinBounds sz (FileSizeExact sz') = sz <= sz'
fileSizeWithinBounds sz (FileSizeBound sz') = sz <= sz'
fileSizeWithinBounds _  FileSizeUnknown     = True

-- | Abstraction over HTTP clients
--
-- This avoids insisting on a particular implementation (such as the HTTP
-- package) and allows for other implementations (such as a conduit based one)
data HttpClient = HttpClient {
    -- | Download a file
    httpClientGet :: forall a. URI -> (BodyReader -> IO a) -> IO a

    -- | Download a byte range
    --
    -- Range is starting and (exclusive) end offset in bytes.
  , httpClientGetRange :: forall a. URI -> (Int, Int) -> (BodyReader -> IO a) -> IO a

    -- | Server capabilities
    --
    -- HTTP clients should use 'newServerCapabilities' on initialization.
  , httpClientCapabilities :: ServerCapabilities

    -- | Catch any custom exceptions thrown and wrap them as 'CustomException's
  , httpWrapCustomEx :: forall a. IO a -> IO a
  }

{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

-- | Initialize the repository (and cleanup resources afterwards)
--
-- We allow to specify multiple mirrors to initialize the repository. These
-- are mirrors that can be found "out of band" (out of the scope of the TUF
-- protocol), for example in a @cabal.config@ file. The TUF protocol itself
-- will specify that any of these mirrors can serve a @mirrors.json@ file
-- that itself contains mirrors; we consider these as _additional_ mirrors
-- to the ones that are passed here.
--
-- NOTE: The list of mirrors should be non-empty (and should typically include
-- the primary server).
--
-- TODO: In the future we could allow finer control over precisely which
-- mirrors we use (which combination of the mirrors that are passed as arguments
-- here and the mirrors that we get from @mirrors.json@) as well as indicating
-- mirror preferences.
withRepository
  :: HttpClient            -- ^ Implementation of the HTTP protocol
  -> [URI]                 -- ^ "Out of band" list of mirrors
  -> Cache                 -- ^ Location of local cache
  -> (LogMessage -> IO ()) -- ^ Logger
  -> (Repository -> IO a)  -- ^ Callback
  -> IO a
withRepository http outOfBandMirrors cache logger callback = do
    selectedMirror <- newMVar Nothing
    callback Repository {
        repWithRemote    = flip $ withRemote http selectedMirror cache logger
      , repGetCached     = Local.getCached     cache
      , repGetCachedRoot = Local.getCachedRoot cache
      , repClearCache    = Local.clearCache    cache
      , repGetFromIndex  = Local.getFromIndex  cache
      , repWithMirror    = withMirror http selectedMirror outOfBandMirrors logger
      , repLog           = logger
      }

{-------------------------------------------------------------------------------
  Implementations of the various methods of Repository
-------------------------------------------------------------------------------}

-- | We select a mirror in 'withMirror' (the implementation of 'repWithMirror').
-- Outside the scope of 'withMirror' no mirror is selected, and a call to
-- 'withRemote' will throw an exception. If this exception is ever thrown its
-- a bug: calls to 'withRemote' ('repWithRemote') should _always_ be in the
-- scope of 'repWithMirror'.
type SelectedMirror = MVar (Maybe URI)

-- | Get a file from the server
withRemote :: forall fs a.
              HttpClient -> SelectedMirror -> Cache
           -> (LogMessage -> IO ())
           -> (SelectedFormat fs -> TempPath -> IO a)
           -> RemoteFile fs -> IO a
withRemote httpClient selectedMirror cache logger callback = \remoteFile -> do
   -- NOTE: Cannot use withMVar here, because the callback would be inside
   -- the scope of the withMVar, and there might be further calls to
   -- withRemote made by this callback, leading to deadlock.
   mBaseURI <- readMVar selectedMirror
   case mBaseURI of
     Nothing      -> throwIO $ userError "Internal error: no mirror selected"
     Just baseURI -> go baseURI remoteFile
  where
    -- When we get a request for the timestamp, we download the combined
    -- timestamp/snapshot archive instead, and unpack that archive into a
    -- separate directory. It is important that we don't just overwrite the
    -- local files because these files are not yet verified.
    go :: URI -> RemoteFile fs -> IO a
    go baseURI RemoteTimestamp = do
        logger $ LogDownloading "timestamp-snapshot.json"
        let arPath = "timestamp-snapshot.json"
            arURI  = baseURI { uriPath = uriPath baseURI </> arPath }
            arSz   = FileSizeUnknown -- TODO
        getFile' httpClient arURI arSz "timestamp-snapshot.json" $ \tempPath -> do
          createDirectoryIfMissing True (cache </> "unverified")
          mAr <- readCanonical KeyEnv.empty tempPath
          case mAr of
            Left  ex -> throwIO ex
            Right ar -> Archive.writeEntries (cache </> "unverified") ar
        let tempTS = cache </> "unverified" </> "timestamp.json"
        result <- callback (SZ FUn) tempTS
        Local.cacheRemoteFile cache tempTS (Some FUn) (CacheAs CachedTimestamp)
        return result

    -- When we get a request for the snapshot, we assume we have previously
    -- gotten a request for the timestamp, so we just use the file we extracted
    -- from the combined timestamp/snapshot archive
    go _baseURI (RemoteSnapshot _) = do
        let tempSS = cache </> "unverified" </> "snapshot.json"
        result <- callback (SZ FUn) tempSS
        Local.cacheRemoteFile cache tempSS (Some FUn) (CacheAs CachedSnapshot)
        return result

    -- Other files we download normally (incrementally if possible)
    go baseURI remoteFile = do
        mIncremental <- shouldDoIncremental httpClient cache remoteFile

        -- Try to download incrementally. However, if this throws an I/O
        -- exception or a verification error we try again using a full download
        didDownload <- case mIncremental of
          Left Nothing ->
            return Nothing
          Left (Just failure) -> do
            logger $ LogUpdateFailed (describeRemoteFile remoteFile) failure
            return Nothing
          Right (sf, len, fp) -> do
            logger $ LogUpdating (describeRemoteFile remoteFile)
            let incr = incTar httpClient baseURI cache (callback sf) len fp
            catchRecoverable (Just <$> incr) $ \ex -> do
              let failure = UpdateFailed ex
              logger $ LogUpdateFailed (describeRemoteFile remoteFile) failure
              return Nothing

        case didDownload of
          Just did -> return did
          Nothing  -> do
            logger $ LogDownloading (describeRemoteFile remoteFile)
            getFile httpClient baseURI cache callback remoteFile

-- | Should we do an incremental update?
--
-- Returns either 'Left' the reason why we cannot do an incremental update (or
-- @Nothing@ if we simply never update this kind of file), or else 'Right' the
-- name of the local file that we should update.
shouldDoIncremental
  :: forall fs. HttpClient -> Cache -> RemoteFile fs
  -> IO (Either (Maybe UpdateFailure)
                (SelectedFormat fs, Trusted FileLength, FilePath))
shouldDoIncremental HttpClient{..} cache remoteFile = runExceptT $ do
    -- Currently the only file which we download incrementally is the index
    formats :: Formats fs (Trusted FileLength) <-
      case remoteFile of
        RemoteIndex _ lens -> return lens
        _ -> throwError Nothing

    -- The server must be able to provide the index in uncompressed form
    -- NOTE: The two @SZ Fun@ expressions here have different types.
    (selected :: SelectedFormat fs, len :: Trusted FileLength) <-
      case formats of
        FsUn   lenUn   -> return (SZ FUn, lenUn)
        FsUnGz lenUn _ -> return (SZ FUn, lenUn)
        _ -> throwError $ Just UpdateImpossibleOnlyCompressed

    -- Server must support @Range@ with a byte-range
    supportsAcceptBytes <- lift $ getServerSupportsAcceptBytes httpClientCapabilities
    unless supportsAcceptBytes $
      throwError $ Just UpdateImpossibleUnsupported

    -- We already have a local file to be updated
    -- (if not we should try to download the initial file in compressed form)
    cachedIndex <- do
      mCachedIndex <- lift $ Local.getCachedIndex cache
      case mCachedIndex of
        Nothing -> throwError $ Just UpdateImpossibleNoLocalCopy
        Just fp -> return fp

    -- TODO: Other factors to decide whether or not we want to do incremental updates
    -- TODO: (Not here:) deal with transparent compression of the update
    -- (but see <https://github.com/haskell/cabal/issues/678> and
    -- @Distribution.Client.GZipUtils@ in @cabal-install@)

    return (selected, len, cachedIndex)

-- | Get any file from the server, without using incremental updates
getFile :: HttpClient -> URI -> Cache
        -> (SelectedFormat fs -> TempPath -> IO a)
        -> RemoteFile fs -> IO a
getFile httpClient baseURI cache callback remoteFile =
    getFile' httpClient uri sz (describeRemoteFile remoteFile) $ \tempPath -> do
      result <- callback format tempPath
      Local.cacheRemoteFile cache
                            tempPath
                            (selectedFormatSome format)
                            (mustCache remoteFile)
      return result
  where
    (format, (uri, sz)) = formatsPrefer
                            (remoteFileNonEmpty remoteFile)
                            FGz
                            (formatsZip
                              (remoteFileURI baseURI remoteFile)
                              (remoteFileSize remoteFile))

-- | Get a file from the server (by URI)
getFile' :: HttpClient          -- ^ HTTP client
         -> URI                 -- ^ File URI
         -> FileSize            -- ^ File size
         -> String              -- ^ File description (for error messages)
         -> (TempPath -> IO a)  -- ^ Callback
         -> IO a
getFile' HttpClient{..} uri sz description callback =
    withSystemTempFile (takeFileName (uriPath uri)) $ \tempPath h -> do
      -- We are careful NOT to scope the remainder of the computation underneath
      -- the httpClientGet
      httpClientGet uri $ execBodyReader description sz h
      hClose h
      callback tempPath

-- | Get a tar file incrementally
--
-- Sadly, this has some tar-specific functionality
incTar :: HttpClient -> URI -> Cache
       -> (TempPath -> IO a)
       -> Trusted FileLength -> FilePath -> IO a
incTar HttpClient{..} baseURI cache callback len cachedFile = do
    -- TODO: Once we have a local tarball index, this is not necessary
    currentSize <- getFileSize cachedFile
    let currentMinusTrailer = currentSize - 1024
        range   = (fromInteger currentMinusTrailer, trustedFileLength len)
        rangeSz = FileSizeExact (snd range - fst range)
    withSystemTempFile (takeFileName (uriPath uri)) $ \tempPath h -> do
      BS.L.hPut h =<< BS.L.readFile cachedFile
      hSeek h AbsoluteSeek currentMinusTrailer
      -- As in 'getFile', make sure we don't scope the remainder of the
      -- computation underneath the httpClientGetRange
      httpClientGetRange uri range $ execBodyReader "index" rangeSz h
      hClose h
      result <- callback tempPath
      Local.cacheRemoteFile cache tempPath (Some FUn) CacheIndex
      return result
  where
    -- TODO: There are hardcoded references to "00-index.tar" and
    -- "00-index.tar.gz" everwhere. We should probably abstract over that.
    uri = baseURI { uriPath = uriPath baseURI </> "00-index.tar" }

-- | Mirror selection
withMirror :: forall a.
              HttpClient -> SelectedMirror -> [URI] -> (LogMessage -> IO ())
           -> Maybe [Mirror] -> IO a -> IO a
withMirror HttpClient{..} selectedMirror outOfBandMirrors logger tufMirrors callback = do
    -- TODO: In the future we will want to make the construction of this list
    -- configurable.
    let mirrorsToTry = outOfBandMirrors
                    ++ maybe [] (map mirrorUrlBase) tufMirrors
    go mirrorsToTry
  where
    go :: [URI] -> IO a
    -- Empty list of mirrors is a bug
    go [] = throwIO $ userError "No mirrors configured"
    -- If we only have a single mirror left, let exceptions be thrown up
    go [m] = do
      logger $ LogSelectedMirror (show m)
      select m $ callback
    -- Otherwise, catch exceptions and if any were thrown, try with different
    -- mirror
    go (m:ms) = do
      logger $ LogSelectedMirror (show m)
      catchRecoverable (httpWrapCustomEx $ select m callback) $ \ex -> do
        logger $ LogMirrorFailed (show m) ex
        go ms

    select :: URI -> IO a -> IO a
    select uri =
      bracket_ (modifyMVar_ selectedMirror $ \_ -> return $ Just uri)
               (modifyMVar_ selectedMirror $ \_ -> return Nothing)

{-------------------------------------------------------------------------------
  Body readers
-------------------------------------------------------------------------------}

-- | An @IO@ action that represents an incoming response body coming from the
-- server.
--
-- The action gets a single chunk of data from the response body, or an empty
-- bytestring if no more data is available.
--
-- This definition is copied from the @http-client@ package.
type BodyReader = IO BS.ByteString

-- | Execute a body reader
--
-- NOTE: This intentially does NOT use the @with..@ pattern: we want to execute
-- the entire body reader (or cancel it) and write the results to a file and
-- then continue. We do NOT want to scope the remainder of the computation
-- as part of the same HTTP request.
--
-- TODO: Deal with minimum download rate.
execBodyReader :: String      -- ^ Description of the file (for error msgs only)
               -> FileSize    -- ^ Maximum file size
               -> Handle      -- ^ Handle to write data too
               -> BodyReader  -- ^ The action to give us blocks from the file
               -> IO ()
execBodyReader file mlen h br = go 0
  where
    go :: Int -> IO ()
    go sz = do
      unless (sz `fileSizeWithinBounds` mlen) $
        throwIO $ VerificationErrorFileTooLarge file
      bs <- br
      if BS.null bs
        then return ()
        else BS.hPut h bs >> go (sz + BS.length bs)

{-------------------------------------------------------------------------------
  Information about remote files
-------------------------------------------------------------------------------}

remoteFileURI :: URI -> RemoteFile fs -> Formats fs URI
remoteFileURI baseURI = fmap aux . remoteFilePath
  where
    aux :: FilePath -> URI
    aux remotePath = baseURI { uriPath = uriPath baseURI </> remotePath }

-- | Extracting or estimating file sizes
--
-- TODO: Put in estimates
remoteFileSize :: RemoteFile fs -> Formats fs FileSize
remoteFileSize (RemoteTimestamp) =
    FsUn FileSizeUnknown
remoteFileSize (RemoteRoot mLen) =
    FsUn $ maybe FileSizeUnknown (FileSizeExact . trustedFileLength) mLen
remoteFileSize (RemoteSnapshot len) =
    FsUn $ FileSizeExact (trustedFileLength len)
remoteFileSize (RemoteMirrors len) =
    FsUn $ FileSizeExact (trustedFileLength len)
remoteFileSize (RemoteIndex _ lens) =
    fmap (FileSizeExact . trustedFileLength) lens
remoteFileSize (RemotePkgTarGz _pkgId len) =
    FsGz $ FileSizeExact (trustedFileLength len)
