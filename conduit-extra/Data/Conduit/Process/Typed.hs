{-# LANGUAGE DataKinds #-}

-- | The "System.Process.Typed" module from @typed-process@, but with
-- added conduit helpers.
module Data.Conduit.Process.Typed
  ( -- * Conduit specific stuff
    createSink
  , createSinkClose
  , createSource
    -- * Running a process with logging
  , withLoggedProcess_
    -- * Reexports
  , module System.Process.Typed
  ) where

import System.Process.Typed
import qualified System.Process.Typed as P
import Data.Conduit (ConduitM, (.|), runConduit)
import qualified Data.Conduit.Binary as CB
import Control.Monad.IO.Unlift
import qualified Data.ByteString as S
import qualified Data.Conduit.List as CL
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, newIORef, readIORef, modifyIORef)
import Control.Exception (throwIO, catch)
import Control.Concurrent.Async (concurrently)
import System.IO (hSetBuffering, BufferMode (NoBuffering), hClose)

-- | Provide input to a process by writing to a conduit.
--
-- @since 1.2.1
createSink :: MonadIO m => StreamSpec 'STInput (ConduitM S.ByteString o m ())
createSink =
  (\h -> liftIO (hSetBuffering h NoBuffering) >> CB.sinkHandle h)
  `fmap` createPipe

-- | Like 'createSink', but includes a function that can be used to close the
-- pipe, indicating to the child process that there is no more data.
--
-- @since 1.2.1
createSinkClose :: (MonadIO m, MonadIO n) => StreamSpec 'STInput (ConduitM S.ByteString o m (), n ())
createSinkClose =
  (\h -> (liftIO (hSetBuffering h NoBuffering) >> CB.sinkHandle h, liftIO (hClose h)))
  `fmap` createPipe

-- | Read output from a process by read from a conduit.
--
-- @since 1.2.1
createSource :: MonadIO m => StreamSpec 'STOutput (ConduitM i S.ByteString m ())
createSource =
  (\h -> liftIO (hSetBuffering h NoBuffering) >> CB.sourceHandle h)
  `fmap` createPipe

-- | Internal function: like 'createSource', but stick all chunks into
-- the 'IORef'.
createSourceLogged
  :: MonadIO m
  => IORef ([S.ByteString] -> [S.ByteString])
  -> StreamSpec 'STOutput (ConduitM i S.ByteString m ())
createSourceLogged ref =
    -- We do not add a cleanup action to close the handle, since in
    -- withLoggedProcess_ we attempt to read from the handle twice
    (\h ->
       (  CB.sourceHandle h
       .| CL.iterM (\bs -> liftIO $ modifyIORef ref (. (bs:))))
    )
    `fmap` createPipe

-- | Run a process, throwing an exception on a failure exit code. This
-- will store all output from stdout and stderr in memory for better
-- error messages. Note that this will require unbounded memory usage,
-- so caveat emptor.
--
-- This will ignore any previous settings for the stdout and stderr
-- streams, and instead force them to use 'createSource'.
--
-- @since 1.2.3
withLoggedProcess_
  :: MonadUnliftIO m
  => ProcessConfig stdin stdoutIgnored stderrIgnored
  -> (Process stdin (ConduitM () S.ByteString m ()) (ConduitM () S.ByteString m ()) -> m a)
  -> m a
withLoggedProcess_ pc inner = withUnliftIO $ \u -> do
  stdoutBuffer <- newIORef id
  stderrBuffer <- newIORef id
  let pc' = setStdout (createSourceLogged stdoutBuffer)
          $ setStderr (createSourceLogged stderrBuffer) pc
  -- withProcessWait vs Term doesn't actually matter here, since we
  -- call checkExitCode inside regardless. But still, Wait is the
  -- safer function to use in general.
  P.withProcessWait pc' $ \p -> do
    a <- unliftIO u $ inner p
    let drain src = unliftIO u (runConduit (src .| CL.sinkNull))
    ((), ()) <- drain (getStdout p) `concurrently`
                drain (getStderr p)
    checkExitCode p `catch` \ece -> do
      stdout <- readIORef stdoutBuffer
      stderr <- readIORef stderrBuffer
      throwIO ece
        { eceStdout = BL.fromChunks $ stdout []
        , eceStderr = BL.fromChunks $ stderr []
        }
    return a
