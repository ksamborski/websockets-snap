--------------------------------------------------------------------------------
-- | Snap integration for the WebSockets library
{-# LANGUAGE DeriveDataTypeable #-}
module Network.WebSockets.Snap
    ( runWebSocketsSnap
    , runWebSocketsSnapWith
    ) where


--------------------------------------------------------------------------------
import           Control.Concurrent            (forkIO, myThreadId, threadDelay)
import           Control.Concurrent.MVar       (MVar, newEmptyMVar, putMVar,
                                                takeMVar)
import           Control.Exception             (Exception (..),
                                                SomeException (..), finally,
                                                handle, throwIO, throwTo, catch)
import           Control.Monad                 (forever)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Lazy          as BL
import qualified Data.ByteString.Builder       as BL
import           Data.Typeable                 (Typeable, cast)
import qualified System.IO.Streams             as Streams
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Network.WebSockets.Stream     as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Types.Headers            as Headers


--------------------------------------------------------------------------------
data Chunk
    = Chunk ByteString
    | Eof
    | Error SomeException
    deriving (Show)


--------------------------------------------------------------------------------
data ServerAppDone = ServerAppDone
    deriving (Eq, Ord, Show, Typeable)


--------------------------------------------------------------------------------
instance Exception ServerAppDone where
    toException ServerAppDone       = SomeException ServerAppDone
    fromException (SomeException e) = cast e


--------------------------------------------------------------------------------
copyStreamToMVar
    :: Streams.InputStream ByteString
    -> ((Int -> Int) -> IO ())
    -> MVar Chunk
    -> IO ()
copyStreamToMVar readEnd tickle mvar = catch go handler
  where
    go = do
        mbs <- Streams.read readEnd
        case mbs of
            Just x  -> do
                tickle (max 60)
                putMVar mvar (Chunk x)
                go
            Nothing -> putMVar mvar Eof

    handler se@(SomeException e) = case cast e of
        -- Clean exit
        Just ServerAppDone -> return ()
        -- Actual error
        Nothing            -> putMVar mvar $ Error se


--------------------------------------------------------------------------------
copyMVarToStream :: MVar Chunk -> IO (IO (Maybe ByteString))
copyMVarToStream mvar = return go
  where
    go = do
        chunk <- takeMVar mvar
        case chunk of
            Chunk x                 -> return (Just x)
            Eof                     -> return Nothing
            Error (SomeException e) -> throwIO e


--------------------------------------------------------------------------------
writer :: Streams.OutputStream BL.Builder
       -> (Maybe BL.ByteString -> IO ())
writer writeEnd = go
  where
    go Nothing   = return ()
    go (Just bl) = Streams.write (Just $ BL.lazyByteString bl) writeEnd


--------------------------------------------------------------------------------
-- | The following function escapes from the current 'Snap.Snap' handler, and
-- continues processing the 'WS.WebSockets' action. The action to be executed
-- takes the 'WS.Request' as a parameter, because snap has already read this
-- from the socket.
runWebSocketsSnap
    :: Snap.MonadSnap m
    => WS.ServerApp
    -> m ()
runWebSocketsSnap = runWebSocketsSnapWith WS.defaultConnectionOptions


--------------------------------------------------------------------------------
-- | Variant of 'runWebSocketsSnap' which allows custom options
runWebSocketsSnapWith
    :: Snap.MonadSnap m
    => WS.ConnectionOptions
    -> WS.ServerApp
    -> m ()
runWebSocketsSnapWith options app = do
    rq <- Snap.getRequest
    Snap.escapeHttp $ \tickle readEnd writeEnd -> do

        let write  = writer writeEnd
        thisThread <- myThreadId
        mvar       <- newEmptyMVar
        parse      <- copyMVarToStream mvar
        stream     <- WS.makeStream parse write

        let options' = options
                    { WS.connectionOnPong = do
                            tickle (max 60)
                            WS.connectionOnPong options
                    }

            pc = WS.PendingConnection
                    { WS.pendingOptions  = options'
                    , WS.pendingRequest  = fromSnapRequest rq
                    , WS.pendingOnAccept = forkPingThread tickle
                    , WS.pendingStream   = stream
                    }

        _ <- forkIO $ finally (app pc) $ do
            WS.close stream
            throwTo thisThread ServerAppDone
        copyStreamToMVar readEnd tickle mvar


--------------------------------------------------------------------------------
-- | Start a ping thread in the background
forkPingThread :: ((Int -> Int) -> IO ()) -> WS.Connection -> IO ()
forkPingThread tickle conn = do
    _ <- forkIO pingThread
    return ()
  where
    pingThread = handle ignore $ forever $ do
        WS.sendPing conn (BC.pack "ping")
        tickle (min 15)
        threadDelay $ 30 * 1000 * 1000

    ignore :: SomeException -> IO ()
    ignore _   = return ()


--------------------------------------------------------------------------------
-- | Convert a snap request to a websockets request
fromSnapRequest :: Snap.Request -> WS.RequestHead
fromSnapRequest rq = WS.RequestHead
    { WS.requestPath    = Snap.rqURI rq
    , WS.requestHeaders = Headers.toList (Snap.rqHeaders rq)
    , WS.requestSecure  = Snap.rqIsSecure rq
    }
