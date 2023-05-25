{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NamedFieldPuns #-}
-- |
-- Module: Chainweb.Pact.Types
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Pact Types module for Chainweb
--
module Chainweb.Pact.Types
  ( -- * Pact Db State
    PactDbStatePersist(..)
  , pdbspRestoreFile
  , pdbspPactDbState

    -- * Misc helpers
  , Transactions(..)
  , transactionCoinbase
  , transactionPairs

  , GasSupply(..)
  , GasId(..)
  , EnforceCoinbaseFailure(..)
  , CoinbaseUsePrecompiled(..)

    -- * Transaction State
  , TransactionState(..)
  , txGasModel
  , txGasLimit
  , txGasUsed
  , txGasId
  , txLogs
  , txCache
  , txWarnings

    -- * Transaction Env
  , TransactionEnv(..)
  , txMode
  , txDbEnv
  , txLogger
  , txGasLogger
  , txPublicData
  , txSpvSupport
  , txNetworkId
  , txGasPrice
  , txRequestKey
  , txExecutionConfig

    -- * Transaction Execution Monad
  , TransactionM(..)
  , runTransactionM
  , evalTransactionM
  , execTransactionM

    -- * Pact Service Env
  , PactServiceEnv(..)
  , psMempoolAccess
  , psCheckpointEnv
  , psPdb
  , psBlockHeaderDb
  , psGasModel
  , psMinerRewards
  , psReorgLimit
  , psOnFatalError
  , psVersion
  , psValidateHashesOnReplay
  , psLogger
  , psGasLogger
  , psLoggers
  , psAllowReadsInLocal
  , psIsBatch
  , psCheckpointerDepth
  , psBlockGasLimit
  , psChainId

  , getCheckpointer

    -- * TxContext
  , TxContext(..)
  , ctxToPublicData
  , ctxToPublicData'
  , ctxCurrentBlockHeight
  , ctxVersion
  , getTxContext

    -- * Pact Service State
  , PactServiceState(..)
  , psStateValidated
  , psParentHeader
  , psSpvSupport

  -- * Module cache
  , ModuleInitCache
  , getInitCache
  , updateInitCache

    -- * Pact Service Monad
  , PactServiceM(..)
  , runPactServiceM
  , evalPactServiceM
  , execPactServiceM

    -- * Logging with Pact logger

  , pactLoggers
  , logg_
  , logInfo_
  , logWarn_
  , logError_
  , logDebug_
  , logg
  , logInfo
  , logWarn
  , logError
  , logDebug

    -- * types
  , TxTimeout(..)
  , ApplyCmdExecutionContext(..)
  , ModuleCache

  -- * miscellaneous
  , defaultOnFatalError
  , defaultReorgLimit
  , defaultPactServiceConfig
  , defaultBlockGasLimit
  , defaultModuleCacheLimit
  ) where

import Control.DeepSeq
import Control.Concurrent (tryReadMVar, modifyMVar_)
import Control.Exception (asyncExceptionFromException, asyncExceptionToException, throw)
import Control.Lens
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State.Strict


import Data.Aeson hiding (Error,(.=))
import Data.Default (def)
import Data.Set (Set)
import qualified Data.Map.Strict as M
import Data.Text (pack, unpack, Text)
import Data.Vector (Vector)
import Data.Word

import GHC.Generics (Generic)

import System.LogLevel

-- internal pact modules

import Pact.Interpreter (PactDbEnv(pdPactDbVar))
import Pact.Parse (ParsedDecimal)
import Pact.Types.ChainId (NetworkId)
import Pact.Types.ChainMeta
import Pact.Types.Command
import Pact.Types.Gas
import qualified Pact.Types.Logger as P
import Pact.Types.Persistence (ExecutionMode, TxLog, PersistModuleData)
import Pact.Types.Runtime (ExecutionConfig(..), PactWarning)
import Pact.Types.SPV
import Pact.Types.Term

-- internal chainweb modules

import Chainweb.BlockCreationTime
import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeight
import Chainweb.BlockHeaderDB
import Chainweb.Mempool.Mempool (TransactionHash)
import Chainweb.Miner.Pact
import Chainweb.Logger
import Chainweb.Pact.Backend.DbCache
import Chainweb.Pact.Backend.Types
import Chainweb.Pact.Service.Types
import Chainweb.Payload.PayloadStore
import Chainweb.Time
import Chainweb.Transaction
import Chainweb.Utils
import Chainweb.Version

import qualified Debug.Trace as DT

data Transactions r = Transactions
    { _transactionPairs :: !(Vector (ChainwebTransaction, r))
    , _transactionCoinbase :: !(CommandResult [TxLog Value])
    } deriving (Functor, Foldable, Traversable, Eq, Show, Generic, NFData)
makeLenses 'Transactions

data PactDbStatePersist = PactDbStatePersist
    { _pdbspRestoreFile :: !(Maybe FilePath)
    , _pdbspPactDbState :: !PactDbState
    }
makeLenses ''PactDbStatePersist

-- -------------------------------------------------------------------------- --
-- Coinbase output utils

-- | Indicates a computed gas charge (gas amount * gas price)
newtype GasSupply = GasSupply { _gasSupply :: ParsedDecimal }
   deriving (Eq,Ord)
   deriving newtype (Num,Real,Fractional, ToJSON,FromJSON)
instance Show GasSupply where show (GasSupply g) = show g

newtype GasId = GasId PactId deriving (Eq, Show)

-- | Whether to enforce coinbase failures, failing the block,
-- or be backward-compatible and allow.
-- Backward-compat fix is to enforce in new block, but ignore in validate.
--
newtype EnforceCoinbaseFailure = EnforceCoinbaseFailure Bool

-- | Always use precompiled templates in coinbase or use date rule.
newtype CoinbaseUsePrecompiled = CoinbaseUsePrecompiled Bool

type ModuleCache = DbCache PersistModuleData

-- -------------------------------------------------------------------- --
-- Local vs. Send execution context flag

data ApplyCmdExecutionContext = ApplyLocal | ApplySend

-- -------------------------------------------------------------------- --
-- Tx Execution Service Monad

-- | Transaction execution state
--
data TransactionState = TransactionState
    { _txCache :: ModuleCache
    , _txLogs :: [TxLog Value]
    , _txGasUsed :: !Gas
    , _txGasId :: !(Maybe GasId)
    , _txGasModel :: !GasModel
    , _txWarnings :: Set PactWarning
    }
makeLenses ''TransactionState

-- | Transaction execution env
--
data TransactionEnv db = TransactionEnv
    { _txMode :: !ExecutionMode
    , _txDbEnv :: PactDbEnv db
    , _txLogger :: !P.Logger
    , _txGasLogger :: !(Maybe P.Logger)
    , _txPublicData :: !PublicData
    , _txSpvSupport :: !SPVSupport
    , _txNetworkId :: !(Maybe NetworkId)
    , _txGasPrice :: !GasPrice
    , _txRequestKey :: !RequestKey
    , _txGasLimit :: !Gas
    , _txExecutionConfig :: !ExecutionConfig
    }
makeLenses ''TransactionEnv

-- | The transaction monad used in transaction execute. The reader
-- environment is the a Pact command env, writer is a list of json-ified
-- tx logs, and transaction state consists of a module cache, gas env,
-- and log values.
--
newtype TransactionM db a = TransactionM
    { _unTransactionM
        :: ReaderT (TransactionEnv db) (StateT TransactionState IO) a
    } deriving newtype
      ( Functor, Applicative, Monad
      , MonadReader (TransactionEnv db)
      , MonadState TransactionState
      , MonadThrow, MonadCatch, MonadMask
      , MonadIO
      )

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, returning the full range of
-- results in a strict tuple
--
runTransactionM
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
      -- ^ computation to execute
    -> IO (T2 a TransactionState)
runTransactionM tenv txst act
    = view (from _T2)
    <$> runStateT (runReaderT (_unTransactionM act) tenv) txst

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, discarding the final state.
--
evalTransactionM
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
    -> IO a
evalTransactionM tenv txst act
    = evalStateT (runReaderT (_unTransactionM act) tenv) txst

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, returning just the final state.
--
execTransactionM
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
    -> IO TransactionState
execTransactionM tenv txst act
    = execStateT (runReaderT (_unTransactionM act) tenv) txst



-- | Pair parent header with transaction metadata.
-- In cases where there is no transaction/Command, 'PublicMeta'
-- default value is used.
data TxContext = TxContext
  { _tcParentHeader :: ParentHeader
  , _tcPublicMeta :: PublicMeta
  }


-- -------------------------------------------------------------------- --
-- Pact Service Monad

data PactServiceEnv tbl = PactServiceEnv
    { _psMempoolAccess :: !(Maybe MemPoolAccess)
    , _psCheckpointEnv :: !CheckpointEnv
    , _psPdb :: !(PayloadDb tbl)
    , _psBlockHeaderDb :: !BlockHeaderDb
    , _psGasModel :: TxContext -> GasModel
    , _psMinerRewards :: !MinerRewards
    , _psReorgLimit :: {-# UNPACK #-} !Word64
    , _psOnFatalError :: forall a. PactException -> Text -> IO a
    , _psVersion :: ChainwebVersion
    , _psValidateHashesOnReplay :: !Bool
    , _psAllowReadsInLocal :: !Bool
    , _psLogger :: !P.Logger
    , _psGasLogger :: !(Maybe P.Logger)
    , _psLoggers :: !P.Loggers
        -- ^ logger factory. A new logger can be created via
        --
        -- P.newLogger loggers (P.LogName "myLogger")

    -- The following two fields are used to enforce invariants for using the
    -- checkpointer. These would better be enforced on the type level. But that
    -- would require changing many function signatures and is postponed for now.
    --
    -- DO NOT use these fields if you don't know what they do!
    --
    , _psIsBatch :: !Bool
        -- ^ True when within a `withBatch` or `withDiscardBatch` call.
    , _psCheckpointerDepth :: !Int
        -- ^ Number of nested checkpointer calls
    , _psBlockGasLimit :: !GasLimit
    , _psChainId :: ChainId
    }
makeLenses ''PactServiceEnv

instance HasChainwebVersion (PactServiceEnv c) where
    _chainwebVersion = _chainwebVersion . _psBlockHeaderDb
    {-# INLINE _chainwebVersion #-}

instance HasChainId (PactServiceEnv c) where
    _chainId = _chainId . _psBlockHeaderDb
    {-# INLINE _chainId #-}

defaultReorgLimit :: Word64
defaultReorgLimit = 480

-- | NOTE this is only used for tests/benchmarks. DO NOT USE IN PROD
defaultPactServiceConfig :: PactServiceConfig
defaultPactServiceConfig = PactServiceConfig
      { _pactReorgLimit = fromIntegral defaultReorgLimit
      , _pactRevalidate = True
      , _pactQueueSize = 1000
      , _pactResetDb = True
      , _pactAllowReadsInLocal = False
      , _pactUnlimitedInitialRewind = False
      , _pactBlockGasLimit = defaultBlockGasLimit
      , _pactLogGas = False
      , _pactModuleCacheLimit = defaultModuleCacheLimit
      }

-- | This default value is only relevant for testing. In a chainweb-node the @GasLimit@
-- is initialized from the @_configBlockGasLimit@ value of @ChainwebConfiguration@.
--
defaultBlockGasLimit :: GasLimit
defaultBlockGasLimit = 10000

newtype ReorgLimitExceeded = ReorgLimitExceeded Text

instance Show ReorgLimitExceeded where
  show (ReorgLimitExceeded t) = "reorg limit exceeded: \n" <> unpack t

instance Exception ReorgLimitExceeded where
    fromException = asyncExceptionFromException
    toException = asyncExceptionToException

newtype TxTimeout = TxTimeout TransactionHash
    deriving Show
instance Exception TxTimeout

defaultOnFatalError :: forall a. (LogLevel -> Text -> IO ()) -> PactException -> Text -> IO a
defaultOnFatalError lf pex t = do
    lf Error errMsg
    throw $ ReorgLimitExceeded errMsg
  where
    errMsg = pack (show pex) <> "\n" <> t

type ModuleInitCache = M.Map BlockHeight ModuleCache

data PactServiceState = PactServiceState
    { _psStateValidated :: !(Maybe BlockHeader)
    , _psParentHeader :: !ParentHeader
    , _psSpvSupport :: !SPVSupport
    }
makeLenses ''PactServiceState

-- | Look up an init cache that is stored at or before the height of the current parent header.
getInitCache :: PactServiceM tbl ModuleCache
getInitCache = do
  DT.traceShowM ("getInitCache" :: String)

  checkpointer <- getCheckpointer
  PactServiceState{_psParentHeader} <- get
  let
    ph = _parentHeader _psParentHeader
    checkpointerTarget = Just (_blockHeight ph + 1, _blockHash ph)
  liftIO $! _cpRestore checkpointer checkpointerTarget >>= \case
    PactDbEnv' pactdbenv -> tryReadMVar (pdPactDbVar pactdbenv) >>= \case
      Just benv -> pure $ _bsModuleCache $ _benvBlockState benv
      Nothing -> pure $ emptyDbCache defaultModuleCacheLimit

-- | Update init cache at adjusted parent block height (APBH).
-- Contents are merged with cache found at or before APBH.
-- APBH is 0 for genesis and (parent block height + 1) thereafter.
updateInitCache :: ModuleCache -> PactServiceM tbl ()
updateInitCache mc = do
  DT.traceShowM ("updateInitCache" :: String)

  checkpointer <- getCheckpointer
  PactServiceState{_psParentHeader} <- get
  let bf 0 = 0
      bf h = succ h
      ph = _parentHeader _psParentHeader
      pbh = bf . _blockHeight $ ph
      checkpointerTarget = Just (pbh, _blockHash ph)

  v <- view psVersion
  liftIO $! _cpRestore checkpointer checkpointerTarget >>= \case
    PactDbEnv' pactdbenv ->
      void $ modifyMVar_ (pdPactDbVar pactdbenv) $ \db -> do
        let mc'
              | chainweb217Pact After v pbh || chainweb217Pact At v pbh = mc
              | otherwise = unionDbCache mc (view (benvBlockState . bsModuleCache) db)
            !db' = set (benvBlockState . bsModuleCache) mc' db
        return db'

-- | Convert context to datatype for Pact environment.
--
-- TODO: this should be deprecated, since the `ctxBlockHeader`
-- call fetches a grandparent, not the parent.
--
ctxToPublicData :: TxContext -> PublicData
ctxToPublicData ctx@(TxContext _ pm) = PublicData
    { _pdPublicMeta = pm
    , _pdBlockHeight = bh
    , _pdBlockTime = bt
    , _pdPrevBlockHash = toText hsh
    }
  where
    h = ctxBlockHeader ctx
    BlockHeight bh = ctxCurrentBlockHeight ctx
    BlockCreationTime (Time (TimeSpan (Micros !bt))) = _blockCreationTime h
    BlockHash hsh = _blockParent h

-- | Convert context to datatype for Pact environment using the
-- current blockheight, referencing the parent header (not grandparent!)
-- hash and blocktime data
--
ctxToPublicData' :: TxContext -> PublicData
ctxToPublicData' (TxContext ph pm) = PublicData
    { _pdPublicMeta = pm
    , _pdBlockHeight = bh
    , _pdBlockTime = bt
    , _pdPrevBlockHash = toText h
    }
  where
    bheader = _parentHeader ph
    BlockHeight !bh = succ $ _blockHeight bheader
    BlockCreationTime (Time (TimeSpan (Micros !bt))) =
      _blockCreationTime bheader
    BlockHash h = _blockHash bheader

-- | Retreive parent header as 'BlockHeader'
ctxBlockHeader :: TxContext -> BlockHeader
ctxBlockHeader = _parentHeader . _tcParentHeader

-- | Get "current" block height, which means parent height + 1.
-- This reflects Pact environment focus on current block height,
-- which influenced legacy switch checks as well.
ctxCurrentBlockHeight :: TxContext -> BlockHeight
ctxCurrentBlockHeight = succ . _blockHeight . ctxBlockHeader

ctxVersion :: TxContext -> ChainwebVersion
ctxVersion = _blockChainwebVersion . ctxBlockHeader

-- | Assemble tx context from transaction metadata and parent header.
getTxContext :: PublicMeta -> PactServiceM tbl TxContext
getTxContext pm = use psParentHeader >>= \ph -> return (TxContext ph pm)


newtype PactServiceM tbl a = PactServiceM
  { _unPactServiceM ::
       ReaderT (PactServiceEnv tbl) (StateT PactServiceState IO) a
  } deriving newtype
    ( Functor, Applicative, Monad
    , MonadReader (PactServiceEnv tbl)
    , MonadState PactServiceState
    , MonadThrow, MonadCatch, MonadMask
    , MonadIO
    )

-- | Run a 'PactServiceM' computation given some initial
-- reader and state values, returning final value and
-- final program state
--
runPactServiceM
    :: PactServiceState
    -> PactServiceEnv tbl
    -> PactServiceM tbl a
    -> IO (T2 a PactServiceState)
runPactServiceM st env act
    = view (from _T2)
    <$> runStateT (runReaderT (_unPactServiceM act) env) st


-- | Run a 'PactServiceM' computation given some initial
-- reader and state values, discarding final state
--
evalPactServiceM
    :: PactServiceState
    -> PactServiceEnv tbl
    -> PactServiceM tbl a
    -> IO a
evalPactServiceM st env act
    = evalStateT (runReaderT (_unPactServiceM act) env) st

-- | Run a 'PactServiceM' computation given some initial
-- reader and state values, discarding final state
--
execPactServiceM
    :: PactServiceState
    -> PactServiceEnv tbl
    -> PactServiceM tbl a
    -> IO PactServiceState
execPactServiceM st env act
    = execStateT (runReaderT (_unPactServiceM act) env) st


getCheckpointer :: PactServiceM tbl Checkpointer
getCheckpointer = view (psCheckpointEnv . cpeCheckpointer)

-- -------------------------------------------------------------------------- --
-- Pact Logger

pactLogLevel :: String -> LogLevel
pactLogLevel "INFO" = Info
pactLogLevel "ERROR" = Error
pactLogLevel "DEBUG" = Debug
pactLogLevel "WARN" = Warn
pactLogLevel _ = Info

-- | Create Pact Loggers that use the the chainweb logging system as backend.
--
pactLoggers :: Logger logger => logger -> P.Loggers
pactLoggers logger = P.Loggers $ P.mkLogger (error "ignored") fun def
  where
    fun :: P.LoggerLogFun
    fun _ (P.LogName n) cat msg = do
        let namedLogger = addLabel ("logger", pack n) logger
        logFunctionText namedLogger (pactLogLevel cat) $ pack msg

-- | Write log message
--
logg_ :: MonadIO m => P.Logger -> String -> String -> m ()
logg_ logger level msg = liftIO $ P.logLog logger level msg

-- | Write log message using the logger in Checkpointer environment

logInfo_ :: MonadIO m => P.Logger -> String -> m ()
logInfo_ l = logg_ l "INFO"

logWarn_ :: MonadIO m => P.Logger -> String -> m ()
logWarn_ l = logg_ l "WARN"

logError_ :: MonadIO m => P.Logger -> String -> m ()
logError_ l = logg_ l "ERROR"

logDebug_ :: MonadIO m => P.Logger -> String -> m ()
logDebug_ l = logg_ l "DEBUG"

-- | Write log message using the logger in Checkpointer environment
--
logg :: String -> String -> PactServiceM tbl ()
logg level msg = view psLogger >>= \l -> logg_ l level msg

logInfo :: String -> PactServiceM tbl ()
logInfo msg = view psLogger >>= \l -> logInfo_ l msg

logWarn :: String -> PactServiceM tbl ()
logWarn msg = view psLogger >>= \l -> logWarn_ l msg

logError :: String -> PactServiceM tbl ()
logError msg = view psLogger >>= \l -> logError_ l msg

logDebug :: String -> PactServiceM tbl ()
logDebug msg = view psLogger >>= \l -> logDebug_ l msg
