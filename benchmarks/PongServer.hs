{-# LANGUAGE CPP, OverloadedStrings #-}

-- Requires the network-bytestring library.
--
-- Start server and run
--   httperf --server=localhost --port=5002 --uri=/ --num-conns=10000
-- or
--   ab -n 10000 -c 100 http://localhost:5002/

import Args (ljust, parseArgs, positive, theLast)
import Control.Concurrent (forkIO, runInUnboundThread)
import Data.ByteString.Char8 ()
import Data.Function (on)
import Data.Monoid (Monoid(..), Last(..))
import Network.Socket hiding (accept, recv)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as C ()
#ifdef USE_GHC_IO_MANAGER
import Network.Socket (accept)
import Network.Socket.ByteString (recv, sendAll)
#else
import EventSocket (accept, recv, sendAll)
import System.Event.Thread (ensureIOManagerIsRunningWith)
import qualified System.Event.Poll as Poll
#endif
import System.Console.GetOpt (ArgDescr(ReqArg), OptDescr(..))
import System.Environment (getArgs)
import System.Posix.Resource (ResourceLimit(..), ResourceLimits(..),
                              Resource(..), setResourceLimit)

main = do
  (cfg, _) <- parseArgs defaultConfig defaultOptions =<< getArgs
  let listenBacklog = theLast cfgListenBacklog cfg
      port = theLast cfgPort cfg
      lim  = ResourceLimit . fromIntegral . theLast cfgMaxFds $ cfg
      myHints = defaultHints { addrFlags = [AI_PASSIVE]
                             , addrSocketType = Stream }
#ifndef USE_GHC_IO_MANAGER
  ensureIOManagerIsRunning
  --ensureIOManagerIsRunningWith =<< Poll.new
#endif
  setResourceLimit ResourceOpenFiles
      ResourceLimits { softLimit = lim, hardLimit = lim }
  (ai:_) <- getAddrInfo (Just myHints) Nothing (Just port)
  sock <- socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai)
  setSocketOption sock ReuseAddr 1
  bindSocket sock (addrAddress ai)
  listen sock listenBacklog
  runInUnboundThread $ acceptConnections sock

acceptConnections :: Socket -> IO ()
acceptConnections sock = loop
  where
    loop = do
        (c,_) <- accept sock
        forkIO $ client c
        loop

client :: Socket -> IO ()
client sock = do
  recvRequest ""
  sendAll sock msg
  sClose sock
 where
  msg = "HTTP/1.0 200 OK\r\nConnection: Close\r\nContent-Length: 5\r\n\r\nPong!"
  recvRequest r = do
    s <- recv sock 4096
    let t = S.append r s
    if S.null s || "\r\n\r\n" `S.isInfixOf` t
      then return ()
      else recvRequest t

------------------------------------------------------------------------
-- Configuration

data Config = Config {
      cfgListenBacklog :: Last Int
    , cfgMaxFds        :: Last Int
    , cfgPort          :: Last String
    }

defaultConfig :: Config
defaultConfig = Config {
      cfgListenBacklog = ljust 1024
    , cfgMaxFds        = ljust 256
    , cfgPort          = ljust "5002"
    }

instance Monoid Config where
    mempty = Config {
          cfgListenBacklog = mempty
        , cfgMaxFds        = mempty
        , cfgPort          = mempty
        }

    mappend a b = Config {
          cfgListenBacklog = app cfgListenBacklog a b
        , cfgMaxFds        = app cfgMaxFds a b
        , cfgPort          = app cfgPort a b
        }
      where app :: (Monoid b) => (a -> b) -> a -> a -> b
            app = on mappend

defaultOptions :: [OptDescr (IO Config)]
defaultOptions = [
      Option ['p'] ["port"]
          (ReqArg (\s -> return mempty { cfgPort = ljust s }) "N")
          "server port"
    , Option ['m'] ["max-fds"]
          (ReqArg (positive "maximum number of file descriptors" $ \n ->
               mempty { cfgMaxFds = n }) "N")
          "maximum number of file descriptors"
    , Option [] ["listen-backlog"]
          (ReqArg (positive "maximum number of pending connections" $ \n ->
               mempty { cfgListenBacklog = n }) "N")
          "maximum number of pending connections"
    ]
