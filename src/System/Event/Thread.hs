{-# LANGUAGE BangPatterns, ForeignFunctionInterface, NoImplicitPrelude #-}

module System.Event.Thread
    (
      ensureIOManagerIsRunning
    , ensureIOManagerIsRunningWith
    , threadWaitRead
    , threadWaitWrite
    , threadDelay
    , registerDelay
    ) where

import Control.Concurrent.MVar (modifyMVar_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import GHC.Base
import GHC.Conc (TVar, ThreadId, ThreadStatus(..), atomically, forkIO,
                 labelThread, newTVar, threadStatus, writeTVar)
import qualified GHC.Conc as Conc
import GHC.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import System.Event.Internal (Backend)
import GHC.Num (fromInteger)
import GHC.Real (div)
import System.Event.Manager (Event, EventManager, evtRead, evtWrite, loop,
                             newDefaultBackend, newWith, registerFd,
                             unregisterFd_, registerTimeout)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Types (Fd)

-- | Suspends the current thread for a given number of microseconds
-- (GHC only).
--
-- There is no guarantee that the thread will be rescheduled promptly
-- when the delay has expired, but the thread will never continue to
-- run /earlier/ than specified.
threadDelay :: Int -> IO ()
threadDelay time
  | threaded  = waitForDelayEvent time
  | otherwise = Conc.threadDelay time

waitForDelayEvent :: Int -> IO ()
waitForDelayEvent usecs = do
  Running mgr <- readIORef eventManager
  m <- newEmptyMVar
  _ <- registerTimeout mgr (usecs `div` 1000) (putMVar m ())
  takeMVar m

-- | Set the value of returned TVar to True after a given number of
-- microseconds. The caveats associated with threadDelay also apply.
--
registerDelay :: Int -> IO (TVar Bool)
registerDelay usecs
  | threaded  = waitForDelayEventSTM usecs
  | otherwise = error "registerDelay: requires -threaded"

waitForDelayEventSTM :: Int -> IO (TVar Bool)
waitForDelayEventSTM usecs = do
  t <- atomically $ newTVar False
  Running mgr <- readIORef eventManager
  _ <- registerTimeout mgr (usecs `div` 1000) . atomically $ writeTVar t True
  return t   

-- | Block the current thread until data is available to read from the
-- given file descriptor.
threadWaitRead :: Fd -> IO ()
threadWaitRead fd
  | threaded  = threadWait evtRead fd
  | otherwise = Conc.threadWaitRead fd

-- | Block the current thread until the given file descriptor can
-- accept data to write.
threadWaitWrite :: Fd -> IO ()
threadWaitWrite fd
  | threaded  = threadWait evtWrite fd
  | otherwise = Conc.threadWaitWrite fd 

data Managing a = None
                | Running !a

threadWait :: Event -> Fd -> IO ()
threadWait evt fd = do
  m <- newEmptyMVar
  Running mgr <- readIORef eventManager
  _ <- registerFd mgr (\reg _ -> unregisterFd_ mgr reg >> putMVar m ()) fd evt
  takeMVar m

eventManager :: IORef (Managing EventManager)
eventManager = unsafePerformIO $ newIORef None
{-# NOINLINE eventManager #-}

ioManager :: MVar (Managing ThreadId)
ioManager = unsafePerformIO $ newMVar None
{-# NOINLINE ioManager #-}

ensureIOManagerIsRunningWith :: Backend -> IO ()
ensureIOManagerIsRunningWith backend
  | not threaded = return ()
  | otherwise = modifyMVar_ ioManager $ \old -> do
  maybeMgr <- readIORef eventManager
  mgr <- case maybeMgr of
           Running m -> return m
           None      -> do m <- newWith backend
                           writeIORef eventManager $ Running m
                           return m
  let create = do
        !t <- forkIO $ loop mgr
        labelThread t "IOManager"
        return $ Running t
  case old of
    None                -> create
    st@(Running t) -> do
      s <- threadStatus t
      case s of
        ThreadFinished -> create
        ThreadDied     -> create
        _other         -> return st

ensureIOManagerIsRunning :: IO ()
ensureIOManagerIsRunning = ensureIOManagerIsRunningWith =<< newDefaultBackend

foreign import ccall unsafe "rtsSupportsBoundThreads" threaded :: Bool
