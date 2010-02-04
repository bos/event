{-# LANGUAGE ForeignFunctionInterface, GeneralizedNewtypeDeriving #-}

--
-- | A binding to the epoll I/O event notification facility
--
-- epoll is a variant of poll that can be used either as an edge-triggered or
-- a level-triggered interface and scales well to large numbers of watched file
-- descriptors.
--
-- epoll decouples monitor an fd from the process of registering it.
--
module System.Event.EPoll where

#include "EventConfig.h"
#if defined(HAVE_EPOLL)

#include <sys/epoll.h>

import Control.Monad (liftM, liftM2, when)
import Data.Bits (Bits, (.|.), (.&.))
import Data.Monoid (Monoid(..))
import Data.Word (Word32)
import Foreign.C.Error (throwErrnoIfMinus1, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable(..))
#if !defined(HAVE_EPOLL_CREATE1)
import System.Posix.Internals (setCloseOnExec)
#endif
import System.Posix.Types (Fd(..))

import qualified System.Event.Array    as A
import qualified System.Event.Internal as E
import           System.Event.Internal (Timeout(..))

data EPoll = EPoll {
      epollFd     :: {-# UNPACK #-} !EPollFd
    , epollEvents :: {-# UNPACK #-} !(A.Array Event)
    }

-- | Create a new epoll backend.
new :: IO E.Backend
new = E.backend poll modifyFd `liftM` liftM2 EPoll epollCreate (A.new 64)

-- | Change the set of events we are interested in for a given file
-- descriptor.
modifyFd :: EPoll -> Fd -> E.Event -> E.Event -> IO ()
modifyFd ep fd oevt nevt = with (Event (fromEvent nevt) fd) $
                             epollControl (epollFd ep) op fd
  where op | oevt == mempty = controlOpAdd
           | nevt == mempty = controlOpDelete
           | otherwise      = controlOpModify

-- | Select a set of file descriptors which are ready for I/O
-- operations and call @f@ for all ready file descriptors, passing the
-- events that are ready.
poll :: EPoll                     -- ^ state
     -> Timeout                   -- ^ timeout in milliseconds
     -> (Fd -> E.Event -> IO ())  -- ^ I/O callback
     -> IO ()
poll ep timeout f = do
  let events = epollEvents ep

  -- Will return zero if the system call was interupted, in which case
  -- we just return (and try again later.)
  n <- A.unsafeLoad events $ \es cap ->
       epollWait (epollFd ep) es cap $ fromTimeout timeout

  when (n > 0) $ do
    A.forM_ events $ \e -> f (eventFd e) (toEvent (eventTypes e))
    cap <- A.capacity events
    when (cap == n) $ A.ensureCapacity events (2 * cap)

newtype EPollFd = EPollFd CInt

data Event = Event {
      eventTypes :: EventType
    , eventFd    :: Fd
    } deriving (Show)

instance Storable Event where
    sizeOf    _ = #size struct epoll_event
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        ets <- #{peek struct epoll_event, events} ptr
        ed  <- #{peek struct epoll_event, data.fd}   ptr
        return $! Event (EventType ets) ed

    poke ptr e = do
        #{poke struct epoll_event, events} ptr (unEventType $ eventTypes e)
        #{poke struct epoll_event, data.fd}   ptr (eventFd e)

newtype ControlOp = ControlOp CInt

#{enum ControlOp, ControlOp
 , controlOpAdd    = EPOLL_CTL_ADD
 , controlOpModify = EPOLL_CTL_MOD
 , controlOpDelete = EPOLL_CTL_DEL
 }

newtype EventType = EventType {
      unEventType :: Word32
    } deriving (Show, Eq, Num, Bits)

#{enum EventType, EventType
 , epollIn  = EPOLLIN
 , epollOut = EPOLLOUT
 , epollErr = EPOLLERR
 , epollHup = EPOLLHUP
 }

-- | Create a new epoll context, returning a file descriptor associated with the context.
-- The fd may be used for subsequent calls to this epoll context.
--
-- The size parameter to epoll_create is a hint about the expected number of handles.
--
-- The file descriptor returned from epoll_create() should be destroyed via
-- a call to close() after polling is finished
--
epollCreate :: IO EPollFd
epollCreate = do
  fd <- throwErrnoIfMinus1 "epollCreate" $
#if defined(HAVE_EPOLL_CREATE1)
        c_epoll_create1 (#const EPOLL_CLOEXEC)
#else
        c_epoll_create 256 -- argument is ignored
  setCloseOnExec fd
#endif
  return $! EPollFd fd

epollControl :: EPollFd -> ControlOp -> Fd -> Ptr Event -> IO ()
epollControl (EPollFd epfd) (ControlOp op) (Fd fd) event =
    throwErrnoIfMinus1_ "epollControl" $ c_epoll_ctl epfd op fd event

epollWait :: EPollFd -> Ptr Event -> Int -> Int -> IO Int
epollWait (EPollFd epfd) events numEvents timeout =
    fmap fromIntegral .
    E.throwErrnoIfMinus1NoRetry "epollWait" $
    c_epoll_wait epfd events (fromIntegral numEvents) (fromIntegral timeout)

fromEvent :: E.Event -> EventType
fromEvent e = remap E.evtRead  epollIn .|.
              remap E.evtWrite epollOut
  where remap evt to
            | e `E.eventIs` evt = to
            | otherwise         = 0

toEvent :: EventType -> E.Event
toEvent e = remap (epollIn  .|. epollErr .|. epollHup) E.evtRead `mappend`
            remap (epollOut .|. epollErr .|. epollHup) E.evtWrite
  where remap evt to
            | e .&. evt /= 0 = to
            | otherwise      = mempty

fromTimeout :: Timeout -> Int
fromTimeout Forever     = -1
fromTimeout (Timeout s) = ceiling $ 1000 * s

#if defined(HAVE_EPOLL_CREATE1)
foreign import ccall unsafe "sys/epoll.h epoll_create1"
    c_epoll_create1 :: CInt -> IO CInt
#else
foreign import ccall unsafe "sys/epoll.h epoll_create"
    c_epoll_create :: CInt -> IO CInt
#endif

foreign import ccall unsafe "sys/epoll.h epoll_ctl"
    c_epoll_ctl :: CInt -> CInt -> CInt -> Ptr Event -> IO CInt

foreign import ccall safe "sys/epoll.h epoll_wait"
    c_epoll_wait :: CInt -> Ptr Event -> CInt -> CInt -> IO CInt

#endif /* defined(HAVE_EPOLL) */
