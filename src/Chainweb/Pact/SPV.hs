{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}

-- |
-- Module: Chainweb.Pact.PactService
-- Copyright: Copyright © 2018 - 2020 Kadena LLC.
-- License: See LICENSE file
-- Maintainers: Emily Pillmore <emily@kadena.io>
-- Stability: experimental
--
-- Pact Service SPV support
--
module Chainweb.Pact.SPV
( -- * spv support
  pactSPV
, verifySPV
, verifyCont
  -- * spv api utilities
, getTxIdx
) where


import GHC.Stack

import Control.Error
import Control.Lens hiding (index)
import Control.Monad.Catch

import Data.Aeson hiding (Object, (.=))
import Data.Default (def)
import qualified Data.Map.Strict as M
import Data.Text (Text, pack)
import qualified Data.Text.Encoding as T

import Crypto.Hash.Algorithms

import Numeric.Natural

import qualified Streaming.Prelude as S

-- internal chainweb modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.BlockHeight
import Chainweb.Pact.Service.Types
import Chainweb.Pact.Utils (aeson)
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.SPV
import Chainweb.SPV.VerifyProof
import Chainweb.TreeDB
import Chainweb.Utils
import qualified Chainweb.Version as CW

import Data.CAS

-- internal pact modules

import Pact.Types.Command
import Pact.Types.Hash
import Pact.Types.PactValue
import Pact.Types.Runtime
import Pact.Types.SPV


-- | Spv support for pact
--
pactSPV
    :: BlockHeaderDb
      -- ^ handle into the cutdb
    -> BlockHeader
      -- ^ the context for verifying the proof
    -> SPVSupport
pactSPV bdb bh = SPVSupport (verifySPV bdb bh) (verifyCont bdb (_blockHash bh))

-- | SPV transaction verification support. Calls to 'verify-spv' in Pact
-- will thread through this function and verify an SPV receipt, making the
-- requisite calls to the SPV api and verifying the output proof.
--
verifySPV
    :: BlockHeaderDb
      -- ^ handle into the cut db
    -> BlockHeader
        -- ^ the context for verifying the proof
    -> Text
      -- ^ TXOUT or TXIN - defines the type of proof
      -- used in validation
    -> Object Name
      -- ^ the 'TransactionOutputProof' object to validate
    -> IO (Either Text (Object Name))
verifySPV bdb bh typ proof = go typ proof
  where
    cid = CW._chainId bdb

    mkSPVResult' cr j
        | CW.enableSPVBridge (_blockChainwebVersion bh) (_blockHeight bh) =
          return $ Right $ mkSPVResult cr j
        | otherwise = case fromPactValue j of
            TObject o _ -> return $ Right $ o
            _ -> return $ Left "spv-verified tx output has invalid type"

    go s o = case s of
      "TXOUT" -> case extractProof o of
        Left t -> return (Left t)
        Right u
          | (view outputProofChainId u) /= cid ->
            internalError "cannot redeem spv proof on wrong target chain"
          | otherwise -> do

            -- SPV proof verification is a 3 step process:
            --
            --  1. verify spv tx output proof via chainweb spv api
            --
            --  2. Decode tx outputs to 'HashCommandResult'
            --
            --  3. Extract tx outputs as a pact object and return the
            --  object.

            TransactionOutput p <- verifyTransactionOutputProofAt_ bdb u (_blockHash bh)

            q <- case decodeStrict' p :: Maybe (CommandResult Hash) of
              Nothing -> internalError "unable to decode spv transaction output"
              Just cr -> return cr

            case _crResult q of
              PactResult Left{} ->
                return (Left "Failed command result in tx output proof")
              PactResult (Right v) -> mkSPVResult' q v

      t -> return . Left $! "unsupported SPV types: " <> t



-- | SPV defpact transaction verification support. This call validates a pact 'endorsement'
-- in Pact, providing a validation that the yield data of a cross-chain pact is valid.
--
verifyCont
    :: BlockHeaderDb
      -- ^ handle into the cut db
    -> BlockHash
        -- ^ the context for verifying the proof
    -> ContProof
      -- ^ bytestring of 'TransactionOutputP roof' object to validate
    -> IO (Either Text PactExec)
verifyCont bdb bh (ContProof cp) = do
    t <- decodeB64UrlNoPaddingText $ T.decodeUtf8 cp
    case decodeStrict' t of
      Nothing -> internalError "unable to decode continuation proof"
      Just u
        | (view outputProofChainId u) /= cid ->
          internalError "cannot redeem continuation proof on wrong target chain"
        | otherwise -> do

          -- Cont proof verification is a 3 step process:
          --
          --  1. verify spv tx output proof via chainweb spv api
          --
          --  2. Decode tx outputs to 'HashCommandResult'
          --
          --  3. Extract continuation 'PactExec' from decoded result
          --  and return the cont exec object

          TransactionOutput p <- verifyTransactionOutputProofAt_ bdb u bh

          q <- case decodeStrict' p :: Maybe (CommandResult Hash) of
            Nothing -> internalError "unable to decode spv transaction output"
            Just cr -> return cr

          case _crContinuation q of
            Nothing -> return (Left "no pact exec found in command result")
            Just pe -> return (Right pe)
  where
    cid = CW._chainId bdb

-- | Extract a 'TransactionOutputProof' from a generic pact object
--
extractProof :: Object Name -> Either Text (TransactionOutputProof SHA512t_256)
extractProof o = toPactValue (TObject o def) >>= k
  where
    k = aeson (Left . pack) Right
      . fromJSON
      . toJSON

-- | Look up pact tx hash at some block height in the
-- payload db, and return the tx index for proof creation.
--
-- Note: runs in O(n) - this should be revisited if possible
--
getTxIdx
    :: HasCallStack
    => PayloadCasLookup cas
    => BlockHeaderDb
    -> PayloadDb cas
    -> BlockHeight
    -> PactHash
    -> IO (Either Text Int)
getTxIdx bdb pdb bh th = do
    -- get BlockPayloadHash
    m <- maxEntry bdb
    ph <- seekAncestor bdb m (int bh) >>= \case
        Just x -> return $ Right $! _blockPayloadHash x
        Nothing -> return $ Left "unable to find payload associated with transaction hash"

    case ph of
      (Left !s) -> return $ Left s
      (Right !a) -> do
        -- get payload
        payload <- _payloadWithOutputsTransactions <$> casLookupM pdb a

        -- Find transaction index
        r <- S.each payload
          & S.map fst
          & S.mapM toTxHash
          & sindex (== th)

        r & note "unable to find transaction at the given block height"
          & fmap int
          & return
  where
    toPactTx :: MonadThrow m => Transaction -> m (Command Text)
    toPactTx (Transaction b) = decodeStrictOrThrow' b

    toTxHash :: MonadThrow m => Transaction -> m PactHash
    toTxHash = fmap _cmdHash . toPactTx

    sfind :: Monad m => (a -> Bool) -> S.Stream (S.Of a) m () -> m (Maybe a)
    sfind p = S.head_ . S.dropWhile (not . p)

    sindex :: Monad m => (a -> Bool) -> S.Stream (S.Of a) m () -> m (Maybe Natural)
    sindex p s = S.zip (S.each [0..]) s & sfind (p . snd) & fmap (fmap fst)


-- | Encode a "successful" CommandResult into a Pact object.
mkSPVResult
    :: CommandResult Hash
       -- ^ Full CR
    -> PactValue
       -- ^ Success result
    -> Object Name
mkSPVResult CommandResult{..} j =
    Object (ObjectMap $ M.fromList $
            [ ("result", fromPactValue j)
            , ("req-key", tStr $ asString $ unRequestKey _crReqKey)
            , ("txid", tStr $ maybe "" asString _crTxId)
            , ("gas", toTerm $ (fromIntegral _crGas :: Integer))
            , ("meta", maybe empty metaField _crMetaData)
            , ("logs", tStr $ asString $ _crLogs)
            , ("continuation", maybe empty contField _crContinuation)
            , ("events", toTList TyAny def $ map eventField _crEvents)
            ])
    TyAny Nothing def
  where
    metaField v = case fromJSON v of
      Error _ -> obj []
      Success p -> fromPactValue p

    contField PactExec{..} = obj
        [ ("step", toTerm _peStep)
        , ("step-count", toTerm _peStepCount)
        , ("yield", maybe empty yieldField _peYield)
        , ("pact-id", toTerm _pePactId)
        , ("cont",contField1 _peContinuation)
        , ("step-has-rollback",toTerm _peStepHasRollback)
        , ("executed",tStr $ maybe "" sshow _peExecuted)
        ]

    contField1 PactContinuation {..} = obj
        [ ("name",tStr $ asString _pcDef)
        , ("args",toTList TyAny def $ map fromPactValue _pcArgs)
        ]

    yieldField Yield {..} = obj
        [ ("data",fromPactValue (PObject _yData))
        , ("provenance", maybe empty provField _yProvenance)
        ]

    provField Provenance {..} = obj
        [ ("target-chain", toTerm $ _chainId _pTargetChainId)
        , ("module-hash", tStr $ asString $ _mhHash $ _pModuleHash)
        ]

    eventField PactEvent {..} = obj
        [ ("name", toTerm _eventName)
        , ("params", toTList TyAny def (map fromPactValue _eventParams))
        , ("module", tStr $ asString _eventModule)
        , ("module-hash", tStr $ asString _eventModuleHash)
        ]

    obj = toTObject TyAny def

    empty = obj []
