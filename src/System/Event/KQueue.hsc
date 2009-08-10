{-# LANGUAGE ForeignFunctionInterface #-}

module System.Event.KQueue where

import Control.Monad
import Data.Bits
import Foreign.C.Error
import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc
import Prelude hiding (filter)

import qualified System.Event.Internal as E

import qualified System.Event.Array as A

#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>

------------------------------------------------------------------------
-- FFI binding

newtype EventQ = EventQ { unEventQ :: CInt }
    deriving (Eq, Show)

data Event = Event {
      ident  :: CUIntPtr
    , filter :: Filter
    , flags  :: Flag
    , fflags :: CUInt
    , data_  :: CIntPtr
    , udata  :: Ptr ()
    } deriving Show

instance Storable Event where
    sizeOf _ = #size struct kevent
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        ident'  <- #{peek struct kevent, ident} ptr
        filter' <- #{peek struct kevent, filter} ptr
        flags'  <- #{peek struct kevent, flags} ptr
        fflags' <- #{peek struct kevent, fflags} ptr
        data'   <- #{peek struct kevent, data} ptr
        udata'  <- #{peek struct kevent, udata} ptr
        return $ Event ident' (Filter filter') (Flag flags') fflags' data'
            udata'

    poke ptr ev = do
        #{poke struct kevent, ident} ptr (ident ev)
        #{poke struct kevent, filter} ptr (unFilter $ filter ev)
        #{poke struct kevent, flags} ptr (unFlag $ flags ev)
        #{poke struct kevent, fflags} ptr (fflags ev)
        #{poke struct kevent, data} ptr (data_ ev)
        #{poke struct kevent, udata} ptr (udata ev)

newtype Flag = Flag { unFlag :: CUShort }
    deriving (Eq, Show)

#{enum Flag, Flag
 , flagAdd     = EV_ADD
 , flagEnable  = EV_ENABLE
 , flagDisable = EV_DISABLE
 , flagDelete  = EV_DELETE
 , flagReceipt = EV_RECEIPT
 , flagOneShot = EV_ONESHOT
 , flagClear   = EV_CLEAR
 , flagEof     = EV_EOF
 , flagError   = EV_ERROR
 }

combineFlags :: [Flag] -> Flag
combineFlags = Flag . foldr ((.|.) . unFlag) 0

newtype Filter = Filter { unFilter :: CShort }
    deriving (Eq, Show)

#{enum Filter, Filter
 , filterRead   = EVFILT_READ
 , filterWrite  = EVFILT_WRITE
 , filterAio    = EVFILT_AIO
 , filterVnode  = EVFILT_VNODE
 , filterProc   = EVFILT_PROC
 , filterSignal = EVFILT_SIGNAL
 , filterTimer  = EVFILT_TIMER
 }

combineFilters :: [Filter] -> Filter
combineFilters = Filter . foldr ((.|.) . unFilter) 0

data TimeSpec = TimeSpec {
      tv_sec  :: CTime
    , tv_nsec :: CLong
    }

instance Storable TimeSpec where
    sizeOf _ = #size struct timespec
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        tv_sec'  <- #{peek struct timespec, tv_sec} ptr
        tv_nsec' <- #{peek struct timespec, tv_nsec} ptr
        return $ TimeSpec tv_sec' tv_nsec'

    poke ptr ts = do
        #{poke struct timespec, tv_sec} ptr (tv_sec ts)
        #{poke struct timespec, tv_nsec} ptr (tv_nsec ts)

foreign import ccall unsafe "event.h kqueue"
    c_kqueue :: IO EventQ

foreign import ccall unsafe "event.h kevent"
    c_kevent :: EventQ -> Ptr Event -> CInt -> Ptr Event -> CInt
             -> Ptr TimeSpec -> IO CInt

kqueue :: IO EventQ
kqueue = EventQ `fmap` throwErrnoIfMinus1
         "kqueue" (fmap unEventQ c_kqueue)

kevent :: EventQ -> Ptr Event -> Int -> Ptr Event -> Int -> Ptr TimeSpec
       -> IO Int
kevent kq chs chlen evs evlen ts
    = fmap fromIntegral $ throwErrnoIfMinus1 "kevent" $
      c_kevent kq chs (fromIntegral chlen) evs (fromIntegral evlen) ts

withTimeSpec :: TimeSpec -> (Ptr TimeSpec -> IO a) -> IO a
withTimeSpec ts f = alloca $ \ptr -> poke ptr ts >> f ptr

------------------------------------------------------------------------
-- Exported interface

data EventQueue = EventQueue {
      kq      :: !EventQ
    , changes :: !(A.Array Event)
    , events  :: !(A.Array Event)
    }

instance E.Backend EventQueue where
    new = new
    poll = poll
    set q fd events = set q fd (combineFilters $ map fromEvent events) flagAdd

new :: IO EventQueue
new = do
    kq' <- kqueue
    changes' <- A.empty
    events' <- A.new 64
    return $ EventQueue kq' changes' events'

set :: EventQueue -> CInt -> Filter -> Flag -> IO ()
set q fd fltr flg =
    A.snoc (changes q) (Event (fromIntegral fd) fltr flg 0 0 nullPtr)

poll :: EventQueue -> (CInt -> [E.Event] -> IO ()) -> IO ()
poll q f = do
    changesLen <- A.length (changes q)
    len <- A.length (events q)
    when (changesLen > len) $ do
        A.ensureCapacity (events q) (2 * changesLen)
    res <- A.useAsPtr (changes q) $ \changesPtr changesLen ->
               A.useAsPtr (events q) $ \eventsPtr eventsLen ->
               withTimeSpec (TimeSpec 1 0) $ \tsPtr ->
               kevent (kq q) changesPtr changesLen eventsPtr eventsLen tsPtr

    when (res > 0) $ putStrLn "events!"

    eventsLen <- A.length (events q)
    when (res == eventsLen) $ do
        A.ensureCapacity (events q) (2 * eventsLen)

    A.mapM_ (events q) $ \e -> do
        let fd = fromIntegral (ident e)
        f fd []

fromEvent :: E.Event -> Filter
fromEvent E.Read  = filterRead
fromEvent E.Write = filterWrite