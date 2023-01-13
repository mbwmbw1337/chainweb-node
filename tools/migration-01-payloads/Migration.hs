{-# language OverloadedStrings #-}
{-# language TypeFamilies #-}
{-# language ViewPatterns #-}

module Main (main) where

import Control.Lens
import Control.Monad

import Data.Foldable
import Data.String
import Data.Word
import System.IO

import qualified Streaming.Prelude as S

import Chainweb.BlockHeaderDB.Internal
import Chainweb.BlockHeader
import Chainweb.BlockHeight
import Chainweb.Payload
import Chainweb.Utils hiding (Codec(..))
import Chainweb.Utils.Serialization
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

import Chainweb.Storage.Table
import Chainweb.Storage.Table.RocksDB

main :: IO ()
main = do
    v <- chainwebVersionFromText . fromString =<< prompt "Version:"
    rocksDbDir <- prompt "RocksDB dir:"
    skipChains <-
        traverse (chainIdFromText . fromString) . splitOn ',' =<<
            prompt "Skip chains (delimit with commas):"
    withRocksDb rocksDbDir modernDefaultOptions $ \rdb ->
        migratePayloadStore v rdb skipChains
    where
    prompt m = putStr m *> hFlush stdout *> getLine
    splitOn _ [] = []
    splitOn c xs =
        let (f,s) = break (/= c) xs
        in f : splitOn c s

data BlockPayloadWithHeight a = BlockPayloadWithHeight !BlockHeight {-# UNPACK #-} !(BlockPayload_ a)

instance IsCasValue (BlockPayloadWithHeight a) where
    type CasKeyType (BlockPayloadWithHeight a) = (BlockHeight, BlockPayloadHash_ a)
    casKey (BlockPayloadWithHeight bh bp) = (bh, casKey bp)

sourcePayloadStore :: RocksDb -> RocksDbTable BlockPayloadHash BlockPayload
sourcePayloadStore db = newTable db
    (Codec encodeToByteString decodeStrictOrThrow')
    (Codec (runPutS . encodeBlockPayloadHash) (runGetS decodeBlockPayloadHash))
    ["BlockPayload"]

targetPayloadStore :: RocksDb -> RocksDbTable (BlockHeight, BlockPayloadHash) BlockPayload
targetPayloadStore db = newTable db
    (Codec encodeToByteString decodeStrictOrThrow')
    (Codec (\(bh, bp) -> runPutS (encodeBlockHeight bh >> encodeBlockPayloadHash bp)) (runGetS ((,) <$> decodeBlockHeight <*> decodeBlockPayloadHash)))
    ["BlockPayload2"]

targetPayloadIndex :: RocksDb -> RocksDbTable BlockPayloadHash BlockHeight
targetPayloadIndex db = newTable db
    (Codec (runPutS . encodeBlockHeight) (runGetS decodeBlockHeight))
    (Codec (runPutS . encodeBlockPayloadHash) (runGetS decodeBlockPayloadHash))
    ["BlockPayloadIndex"]

migratePayloadStore :: ChainwebVersion -> RocksDb -> [ChainId] -> IO ()
migratePayloadStore v rdb skipChains = do
    (view webBlockHeaderDb -> headerDbMap) <- initWebBlockHeaderDb rdb v
    for_ headerDbMap $ \(_chainDbCas -> headerTable) -> do
        withTableIterator headerTable $ \headerIter ->
            iterToValueStream headerIter
                & S.mapM_ migrateHeader
    -- headerDbMap
    -- withTableIter payloadTable $ \iter -> do
    where
    src = sourcePayloadStore rdb
    tgt = targetPayloadStore rdb
    tgtIndex = targetPayloadIndex rdb
    migrateHeader (RankedBlockHeader h) = do
        when (int (_blockHeight h) `mod` (100 :: Word64) == 0) $
            putStrLn $ "migrating chain " <> show (_blockChainId h) <> " at " <> show (_blockHeight h) <> "..."
        unless (elem (_blockChainId h) skipChains) $ do
            Just original <- tableLookup src (_blockPayloadHash h)
            -- putStr "writing..."
            tableInsert tgt (_blockHeight h, _blockPayloadHash h) original
            tableInsert tgtIndex (_blockPayloadHash h) (_blockHeight h)
            -- putStrLn "done"