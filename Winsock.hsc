{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Winsock (
    Socket(..),
    SOCKET,
    socket,
    connect,
    shutdown,
    close,
    recvBuf,
    sendBuf,

    recv,
    send,
) where

#include <windows.h>

##ifdef mingw32_HOST_OS
## if defined(i386_HOST_ARCH)
##  define WINDOWS_CCONV stdcall
## elif defined(x86_64_HOST_ARCH)
##  define WINDOWS_CCONV ccall
## else
##  error Unknown mingw32 arch
## endif
##endif

import IOCP.Manager             (LPOVERLAPPED)
import qualified IOCP.FFI     as FFI
import qualified IOCP.Manager as Mgr

import Control.Applicative      ((<$>))
import Control.Monad            (void)
import Data.ByteString          (ByteString)
import Data.ByteString.Internal (createAndTrim)
import Data.ByteString.Unsafe   (unsafeUseAsCStringLen)
import Data.IORef
import Data.Word
import Foreign.C
import Foreign.Ptr
import Network.Socket.Internal  (withSockAddr)
import System.IO.Unsafe         (unsafePerformIO)
import System.Win32.Types

import qualified Network.Socket     as NS
import qualified System.Win32.Types as Win32

newtype Socket = Socket { sockFd :: SOCKET }
    deriving Eq

-- Note: Functions that take a 'Socket' expect Winsock to already be initialized.

socket :: NS.Family -> NS.SocketType -> NS.ProtocolNumber -> IO Socket
socket family stype protocol = do
    initWinsock
    fd <- fromIntegral . NS.fdSocket <$> NS.socket family stype protocol
    mgr <- getManager
    Mgr.registerHandle mgr (castSOCKETToHANDLE fd)
    return (Socket fd)

getManager :: IO Mgr.Manager
getManager = Mgr.getSystemManager >>= maybe (fail "requires threaded RTS") return

withOverlapped :: SOCKET -> Word64
               -> (LPOVERLAPPED -> IO ())
               -> Mgr.CompletionCallback a
               -> IO a
withOverlapped h offset startCB completionCB = do
    mgr <- getManager
    Mgr.withOverlapped mgr (castSOCKETToHANDLE h) offset startCB completionCB

connect :: Socket -> NS.SockAddr -> IO ()
connect (Socket sock) addr = do
    winsock <- getWinsock
    withOverlapped sock 0 (startCB winsock) completionCB
  where
    startCB winsock overlapped =
        withSockAddr addr $ \addr_ptr addr_len ->
        Win32.failIfFalse_ "connect" $
        c_winsock_connect winsock sock
                          addr_ptr (fromIntegral addr_len)
                          overlapped

    completionCB err _numBytes
        | err == 0  = return ()
        | otherwise = FFI.throwWinErr "connect" err

shutdown :: Socket -> NS.ShutdownCmd -> IO ()
shutdown sock how =
    Win32.failIf_ (/= 0) "shutdown" $
    c_shutdown (sockFd sock) (sdownCmdToInt how)

sdownCmdToInt :: NS.ShutdownCmd -> CInt
sdownCmdToInt NS.ShutdownReceive = #const SD_RECEIVE
sdownCmdToInt NS.ShutdownSend    = #const SD_SEND
sdownCmdToInt NS.ShutdownBoth    = #const SD_BOTH

close :: Socket -> IO ()
close (Socket sock) = do
    mgr <- getManager
    Mgr.closeHandleWith mgr (close' . castHANDLEToSOCKET) (castSOCKETToHANDLE sock)
  where
    close' = Win32.failIf_ (/= 0) "close" . c_closesocket

recvBuf :: Socket -> Ptr a -> Int -> IO Int
recvBuf (Socket sock) buf len =
    withOverlapped sock 0 startCB completionCB
  where
    startCB ol =
        Win32.failIfFalse_ "recv" $
        c_winsock_recv sock (castPtr buf) (fromIntegral len) ol

    completionCB err numBytes
        | err == 0  = return (fromIntegral numBytes)
        | otherwise = FFI.throwWinErr "recv" err

sendBuf :: Socket -> Ptr a -> Int -> IO Int
sendBuf (Socket sock) buf len =
    withOverlapped sock 0 startCB completionCB
  where
    startCB ol =
        Win32.failIfFalse_ "send" $
        c_winsock_send sock (castPtr buf) (fromIntegral len) ol

    completionCB err numBytes
        | err == 0  = return (fromIntegral numBytes)
        | otherwise = FFI.throwWinErr "send" err

recv :: Socket -> Int -> IO ByteString
recv sock len =
    createAndTrim len $ \buf ->
    recvBuf sock buf len

send :: Socket -> ByteString -> IO Int
send sock bs =
    unsafeUseAsCStringLen bs $ \(buf, len) ->
    sendBuf sock buf len

newtype Winsock = Winsock (Ptr ())

getWinsock :: IO Winsock
getWinsock = readIORef winsockRef

initWinsock :: IO ()
initWinsock = void getWinsock

winsockRef :: IORef Winsock
winsockRef = unsafePerformIO (c_winsock_init >>= newIORef)
{-# NOINLINE winsockRef #-}

type SOCKET = #type SOCKET

castSOCKETToHANDLE :: SOCKET -> HANDLE
castSOCKETToHANDLE = wordPtrToPtr . fromIntegral

castHANDLEToSOCKET :: HANDLE -> SOCKET
castHANDLEToSOCKET = fromIntegral . ptrToWordPtr

foreign import ccall unsafe
    c_winsock_init :: IO Winsock

foreign import ccall unsafe
    c_winsock_connect :: Winsock -> SOCKET -> Ptr NS.SockAddr -> CInt -> LPOVERLAPPED -> IO BOOL

foreign import WINDOWS_CCONV safe "winsock2.h shutdown"
    c_shutdown :: SOCKET -> CInt -> IO CInt

foreign import WINDOWS_CCONV safe "winsock2.h closesocket"
    c_closesocket :: SOCKET -> IO CInt

foreign import ccall unsafe
    c_winsock_recv :: SOCKET -> Ptr CChar -> #{type u_long} -> LPOVERLAPPED -> IO BOOL

foreign import ccall unsafe
    c_winsock_send :: SOCKET -> Ptr CChar -> #{type u_long} -> LPOVERLAPPED -> IO BOOL
