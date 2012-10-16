{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

-- | Input and output streams for files.
--
-- The functions in this file use \"with*\" or \"bracket\" semantics, i.e. they
-- open the supplied 'FilePath', run a user computation, and then close the
-- file handle. If you need more control over the lifecycle of the underlying
-- file descriptor resources, you are encouraged to use the functions from
-- "System.IO.Streams.Handle" instead.
module System.IO.Streams.File
  ( -- * File conversions
    withFileAsInput
  , withFileAsInputStartingAt
  , unsafeWithFileAsInputStartingAt
  , withFileAsOutput
  ) where

#ifndef PORTABLE

                                ---------------
                                -- unix mode --
                                ---------------

------------------------------------------------------------------------------
import           Data.ByteString            ( ByteString )
import           Data.Int                   ( Int64 )
import           Control.Exception          ( bracket )
import           Control.Monad              ( liftM, unless, void )
import qualified Data.ByteString.Char8      as S
import qualified Data.ByteString.Internal   as S
import qualified Data.ByteString.Unsafe     as S
import           Foreign.Ptr                ( castPtr, plusPtr )
import           GHC.ForeignPtr             ( mallocPlainForeignPtrBytes )
import           System.IO                  ( IOMode(..)
                                            , SeekMode(AbsoluteSeek)
                                            )
import           System.IO.Posix.MMap       ( unsafeMMapFile )
import           System.Posix.Files         ( fileSize
                                            , getFileStatus
                                            , stdFileMode
                                            )
import           System.Posix.IO            ( OpenMode(..)
                                            , append
                                            , closeFd
                                            , defaultFileFlags
                                            , fdSeek
                                            , fdReadBuf
                                            , fdWriteBuf
                                            , openFd
                                            , trunc
                                            )
import           System.Posix.Types         ( FileOffset )
------------------------------------------------------------------------------
import           System.IO.Streams.Internal ( InputStream
                                            , OutputStream
                                            , makeInputStream
                                            , makeOutputStream
                                            , singletonSource
                                            , sourceToStream
                                            )
#else

                              -------------------
                              -- portable mode --
                              -------------------

------------------------------------------------------------------------------
import           Data.ByteString            ( ByteString )
import           Data.Int                   ( Int64 )
import           Control.Monad              ( unless )
import           System.IO                  ( IOMode(ReadMode)
                                            , SeekMode(AbsoluteSeek)
                                            , hSeek
                                            , withBinaryFile
                                            )
------------------------------------------------------------------------------
import           System.IO.Streams.Internal ( InputStream
                                            , OutputStream
                                            )
import           System.IO.Streams.Handle
#endif


------------------------------------------------------------------------------
-- | @'withFileAsInput' name act@ opens the specified file in \"read mode\" and
-- passes the resulting 'InputStream' to the computation @act@. The file will
-- be closed on exit from @withFileAsInput@, whether by normal termination or
-- by raising an exception.
--
-- If closing the file raises an exception, then /that/ exception will be
-- raised by 'withFileAsInput' rather than any exception raised by @act@.
withFileAsInput :: FilePath                          -- ^ file to open
                -> (InputStream ByteString -> IO a)  -- ^ function to run
                -> IO a
withFileAsInput = withFileAsInputStartingAt 0


------------------------------------------------------------------------------
-- | Like 'withFileAsInput', but seeks to the specified byte offset before
-- attaching the given file descriptor to the 'InputStream'.
withFileAsInputStartingAt
    :: Int64                             -- ^ starting index to seek to
    -> FilePath                          -- ^ file to open
    -> (InputStream ByteString -> IO a)  -- ^ function to run
    -> IO a


------------------------------------------------------------------------------
-- | Like 'withFileAsInputStartingAt', except that the 'ByteString' emitted by
-- the created 'InputStream' may reuse its buffer. You may only use this
-- function if you do not retain references to the generated bytestrings
-- emitted.
unsafeWithFileAsInputStartingAt
    :: Int64                             -- ^ starting index to seek to
    -> FilePath                          -- ^ file to open
    -> (InputStream ByteString -> IO a)  -- ^ function to run
    -> IO a


------------------------------------------------------------------------------
-- | Like 'withFileAsInput', but opens the file for writing using the specified
-- IO mode, and attaches the file to an 'OutputStream' instead of an
-- 'InputStream'.
withFileAsOutput
    :: FilePath                           -- ^ file to open
    -> IOMode                             -- ^ mode to write in
    -> (OutputStream ByteString -> IO a)  -- ^ function to run
    -> IO a


#ifdef PORTABLE
------------------------------------------------------------------------------
withFileAsInputStartingAt idx fp m = withBinaryFile fp ReadMode go
  where
    go h = do
        unless (idx == 0) $ hSeek h AbsoluteSeek $ toInteger idx
        handleToInputStream h >>= m


------------------------------------------------------------------------------
unsafeWithFileAsInputStartingAt = withFileAsInputStartingAt


------------------------------------------------------------------------------
withFileAsOutput fp mode m =
    withBinaryFile fp mode ((m =<<) . handleToOutputStream)


#else
------------------------------------------------------------------------------
maxMMapFileSize :: FileOffset
maxMMapFileSize = 10485760   -- 10MB


------------------------------------------------------------------------------
tooBigForMMap :: FilePath -> IO Bool
tooBigForMMap fp = do
    stat <- getFileStatus fp
    return $! fileSize stat > maxMMapFileSize


------------------------------------------------------------------------------
newBuffer :: Int -> IO (IO ByteString)
newBuffer n = return $ do
    buf <- mallocPlainForeignPtrBytes n
    return $! S.fromForeignPtr buf 0 n


------------------------------------------------------------------------------
reuseBuffer :: Int -> IO (IO ByteString)
reuseBuffer n = do
    buf <- mallocPlainForeignPtrBytes n
    return (return $! S.fromForeignPtr buf 0 n)


------------------------------------------------------------------------------
bUFSIZ :: Int
bUFSIZ = 32752


------------------------------------------------------------------------------
withFileAsInputStartingAt =
    withFileAsInputStartingAtInternal (newBuffer bUFSIZ)


------------------------------------------------------------------------------
unsafeWithFileAsInputStartingAt =
    withFileAsInputStartingAtInternal (reuseBuffer bUFSIZ)


------------------------------------------------------------------------------
withFileAsInputStartingAtInternal
    :: IO (IO ByteString)                -- ^ function to make a new bytestring
                                         --   buffer
    -> Int64                             -- ^ starting index to seek to
    -> FilePath                          -- ^ file to open
    -> (InputStream ByteString -> IO a)  -- ^ function to run
    -> IO a
withFileAsInputStartingAtInternal mkBuf idx fp m = do
    tooBig <- tooBigForMMap fp
    if tooBig then useRead else useMMap

  where
    --------------------------------------------------------------------------
    useMMap = do
        s <- liftM (S.drop (fromEnum idx)) $ unsafeMMapFile fp
        sourceToStream (singletonSource s) >>= m

    --------------------------------------------------------------------------
    useRead = bracket open cleanup mkStream

    --------------------------------------------------------------------------
    open = do
        fd <- openFd fp ReadOnly Nothing defaultFileFlags
        unless (idx == 0) $
            void $ fdSeek fd AbsoluteSeek (toEnum . fromEnum $ idx)

        bufAction <- mkBuf
        return (fd, bufAction)

    --------------------------------------------------------------------------
    cleanup (fd, _) = closeFd fd

    --------------------------------------------------------------------------
    mkStream (fd, bufAction) = makeInputStream (go fd bufAction) >>= m

    --------------------------------------------------------------------------
    go fd bufAction = do
        bs <- bufAction
        S.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
            bytesRead <- fdReadBuf fd (castPtr ptr) (toEnum $ fromEnum len)

            if bytesRead <= 0
              then return Nothing
              else return $! Just $! S.take (fromEnum bytesRead) bs


------------------------------------------------------------------------------
withFileAsOutput fp ioMode m = bracket open closeFd mkStream
  where
    fromIOMode ReadMode      = error "withFileAsOutput called in ReadMode"
    fromIOMode WriteMode     = (WriteOnly, defaultFileFlags { trunc = True })
    fromIOMode AppendMode    = (WriteOnly, defaultFileFlags { append = True })
    fromIOMode ReadWriteMode = (ReadWrite, defaultFileFlags)

    open = do
        let (openMode, flags) = fromIOMode ioMode
        openFd fp openMode (Just stdFileMode) flags

    mkStream fd = makeOutputStream (go fd) >>= m

    go _ Nothing   = return $! ()
    go fd (Just s) = S.unsafeUseAsCStringLen s $ \(ptr, len) ->
                     writeAll (castPtr ptr) (toEnum len)
      where
        writeAll !ptr !len | len <= 0 = return $! ()
                           | otherwise = do
            bytesWritten <- fdWriteBuf fd ptr len
            writeAll (plusPtr ptr (fromEnum bytesWritten))
                     (len - bytesWritten)
#endif
