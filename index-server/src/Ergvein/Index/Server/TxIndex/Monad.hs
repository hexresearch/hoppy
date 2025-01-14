{-# LANGUAGE DerivingVia #-}
module Ergvein.Index.Server.TxIndex.Monad
  (
    TxIndexM(..)
  , TxIndexEnv(..)
  , withTxIndexEnv
  , runTxIndexMIO
  , logOnException
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception hiding (handle)
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.IO.Unlift
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Data.Text (Text)
import Data.Typeable
import Network.HTTP.Client.TLS
import Prometheus (MonadMonitor(..))
import System.IO

import Ergvein.Text
import Ergvein.Index.Server.BlockchainScanning.BitcoinApiMonad
import Ergvein.Index.Server.Config
import Ergvein.Index.Server.DB
import Ergvein.Index.Server.DB.Monad
import Ergvein.Index.Server.DB.Wrapper
import Ergvein.Index.Server.TCPService.BTC
import Ergvein.Index.Server.Dependencies

import qualified Network.Bitcoin.Api.Client  as BitcoinApi
import qualified Network.Haskoin.Constants   as HK
import qualified Network.HTTP.Client         as HC

data TxIndexEnv = TxIndexEnv
    { envServerConfig             :: !Config
    , envLogger                   :: !(Chan (Loc, LogSource, LogLevel, LogStr))
    , envUtxoDBContext            :: !LevelDB
    , envBitcoinNodeNetwork       :: !HK.Network
    , envClientManager            :: !HC.Manager
    , envBitcoinClient            :: !BitcoinApi.Client
    , envBitcoinSocket            :: !BtcSocket
    , envBitcoinSocketReconnect   :: !(IO ())
    , envBtcConScheme             :: !(TVar BtcConnectionScheme)
    -- , envBtcRollback              :: !(TVar (Seq.Seq RollbackRecItem))
    , envShutdownFlag             :: !(TVar Bool)
    , envShutdownChannel          :: !(TChan Bool)
    }

newtype TxIndexM a = TxIndexM { unTxIndexM :: ReaderT TxIndexEnv (LoggingT IO) a }
  deriving newtype ( Functor, Applicative, Monad, MonadIO, MonadLogger
                   , MonadReader TxIndexEnv
                   , MonadThrow, MonadCatch, MonadMask
                   , MonadBase IO, MonadBaseControl IO, MonadUnliftIO)
  -- To avoid orphan we unwrap LoggingT as its reader representation
  deriving MonadMonitor via (ReaderT TxIndexEnv (ReaderT (Loc -> LogSource -> LogLevel -> LogStr -> IO ()) IO))

runTxIndexMIO :: TxIndexEnv -> TxIndexM a -> IO a
runTxIndexMIO e = runChanLoggingT (envLogger e) . flip runReaderT e . unTxIndexM

instance HasUtxoDB TxIndexM where
  getUtxoDb = asks envUtxoDBContext
  {-# INLINE getUtxoDb #-}

instance HasBitcoinNodeNetwork TxIndexM where
  currentBitcoinNetwork = asks envBitcoinNodeNetwork
  {-# INLINE currentBitcoinNetwork #-}

instance HasServerConfig TxIndexM where
  serverConfig = asks envServerConfig
  {-# INLINE serverConfig #-}

instance BitcoinApiMonad TxIndexM where
  nodeRpcCall f = liftIO . f =<< asks envBitcoinClient
  {-# INLINE nodeRpcCall #-}
  getSocketConn = asks envBitcoinSocket
  {-# INLINE getSocketConn #-}
  getBtcConnectionScheme = liftIO . readTVarIO =<< asks envBtcConScheme
  {-# INLINE getBtcConnectionScheme #-}
  restartSocketConn = do
    f <- asks envBitcoinSocketReconnect
    liftIO $ f

-- instance HasClientManager TxIndexM where
--   getClientManager = asks envClientManager
--   {-# INLINE getClientManager #-}

instance HasShutdownFlag TxIndexM where
  getShutdownFlag = asks envShutdownFlag
  {-# INLINE getShutdownFlag #-}

withTxIndexEnv :: (MonadIO m, MonadLogger m, MonadMask m, MonadBaseControl IO m, MonadMask m)
  => Bool               -- ^ flag, def True: wait for node connections to be up before finalizing the env
  -> BitcoinApi.Client  -- ^ RPC connection to the bitcoin node
  -> Config             -- ^ Contents of the config file
  -> (TxIndexEnv -> m a)
  -> m a
withTxIndexEnv useTcp btcClient cfg@Config{..} action = do
    logger <- liftIO newChan
    liftIO $ hSetBuffering stdout LineBuffering
    void $ liftIO $ forkIO $ runStdoutLoggingT $ unChanLoggingT logger
    tlsManager     <- liftIO $ newTlsManager
    shutdownVar    <- liftIO $ newTVarIO False
    shutdownChan   <- liftIO newTChanIO
    btcRestartChan <- liftIO newTChanIO
    btcConnVar     <- liftIO $ newTVarIO $ if useTcp then BtcConTCP else BtcConRPC
    let bitcoinNodeNetwork = if cfgBTCNodeIsTestnet then HK.btcTest else HK.btc
    btcsock <- if useTcp then do
      btcsock <- connectBtc
        bitcoinNodeNetwork
        cfgBTCNodeTCPHost
        (show cfgBTCNodeTCPPort)
        shutdownVar
        btcRestartChan
      liftIO $ do
        isUp <- atomically $ dupTChan $ btcSockOnActive btcsock
        b <- readTVarIO $ btcSockIsActive btcsock
        unless b $ fix $ \next -> do
          b' <- atomically $ readTChan isUp
          unless b' next
      pure btcsock
      else dummyBtcSock bitcoinNodeNetwork
    withDb True DBUtxo cfgUtxoDbPath $ \utxoDBCntx -> action TxIndexEnv
      { envServerConfig            = cfg
      , envLogger                  = logger
      , envUtxoDBContext           = utxoDBCntx
      , envBitcoinNodeNetwork      = bitcoinNodeNetwork
      , envClientManager           = tlsManager
      , envBitcoinClient           = btcClient
      , envBitcoinSocket           = btcsock
      , envBitcoinSocketReconnect  = liftIO (atomically $ writeTChan btcRestartChan ())
      , envBtcConScheme            = btcConnVar
      -- , envBtcRollback             = btcSeqVar
      , envShutdownFlag            = shutdownVar
      , envShutdownChannel         = shutdownChan
      }

-- | Log exceptions at Error severity
logOnException :: (
    HasServerConfig m
  , MonadIO m
  , MonadLogger m
  , MonadCatch m)
  => Text -> m a -> m a
logOnException threadName = handle logE
  where
    logE :: (
        HasServerConfig m
      , MonadIO m
      , MonadLogger m
      , MonadCatch m) => SomeException -> m b
    logE e
        | Just ThreadKilled <- fromException e = do
            logInfoN $ "[" <> threadName <> "]: Killed normally by ThreadKilled"
            throwM e
        | SomeException eTy <- e = do
            logErrorN $ "[" <> threadName <> "]: Killed by " <> showt (typeOf eTy) <> ". " <> showt eTy
            liftIO $ threadDelay 1000000
            throwM e
