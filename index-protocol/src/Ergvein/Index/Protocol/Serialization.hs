module Ergvein.Index.Protocol.Serialization where

import Codec.Compression.GZip
import Data.ByteString.Builder
import Data.Monoid
import Data.Word
import Ergvein.Index.Protocol.Types
import Foreign.C.Types

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as UV

messageTypeToWord32 :: MessageType -> Word32 
messageTypeToWord32 = \case
  Version         -> 0 
  VersionACK      -> 1 
  FiltersRequest  -> 2 
  FiltersResponse -> 3 
  FilterEvent     -> 4 
  PeerRequest     -> 5 
  PeerResponse    -> 6 
  FeeRequest      -> 7 
  FeeResponse     -> 8 
  IntroducePeer   -> 9 
  Reject          -> 10 
  Ping            -> 11
  Pong            -> 12

rejectTypeToWord32 :: RejectCode -> Word32 
rejectTypeToWord32 = \case
  MessageHeaderParsing -> 0
  MessageParsing       -> 1
  InternalServerError  -> 2

messageBase :: MessageType -> Word32 -> Builder -> Builder
messageBase msgType msgLength payload = word32BE (messageTypeToWord32 msgType) <> word32BE msgLength <> payload

scanBlockBuilder :: ScanBlock -> (Sum Word32, Builder)
scanBlockBuilder ScanBlock {..} = (scanBlockSize, scanBlock)
  where
    currencyCode = currencyCodeToWord32 scanBlockCurrency
    scanBlockSize = Sum $ genericSizeOf currencyCode
                        + genericSizeOf scanBlockVersion
                        + genericSizeOf scanBlockScanHeight
                        + genericSizeOf scanBlockHeight

    scanBlock = word32BE currencyCode
             <> word32BE scanBlockVersion
             <> word64BE scanBlockScanHeight
             <> word64BE scanBlockHeight

blockFilterBuilder :: BlockFilter -> (Sum Word32, Builder)
blockFilterBuilder BlockFilter {..} = (filterSize, filterBuilder)
  where
    idLength = fromIntegral $ BS.length blockFilterBlockId
    filterLength = fromIntegral $ BS.length blockFilterFilter
    filterSize = Sum $ genericSizeOf idLength 
                     + idLength
                     + genericSizeOf filterLength
                     + filterLength
    filterBuilder = word32BE idLength
                 <> byteString blockFilterBlockId
                 <> word32BE filterLength
                 <> byteString blockFilterFilter


messageBuilder :: Message -> Builder

messageBuilder (PingMsg msg) = messageBase Ping msgSize $ word64BE msg
  where
    msgSize = genericSizeOf msg

messageBuilder (PongMsg msg) = messageBase Pong msgSize $ word64BE msg
  where
    msgSize = genericSizeOf msg

messageBuilder (RejectMsg msg) = messageBase Reject msgSize $ word32BE rejectType
  where
    rejectType = rejectTypeToWord32 $ rejectMsgCode msg
    msgSize = genericSizeOf rejectType

messageBuilder (VersionACKMsg msg) = messageBase VersionACK msgSize $ mempty
  where
    msgSize = 0

messageBuilder (VersionMsg VersionMessage {..}) = let 
  (scanBlocksSizeSum, scanBlocks) = mconcat $ scanBlockBuilder <$> UV.toList versionMsgScanBlocks
  scanBlocksCount = fromIntegral $ UV.length versionMsgScanBlocks
  scanBlocksSize = getSum scanBlocksSizeSum
  msgSize = genericSizeOf versionMsgVersion
          + genericSizeOf versionMsgTime
          + genericSizeOf versionMsgNonce
          + genericSizeOf scanBlocksCount
          + scanBlocksSize
  (CTime time) = versionMsgTime
  in messageBase Version msgSize 
    $  word32BE versionMsgVersion
    <> word64BE (fromIntegral time)
    <> word64BE versionMsgNonce
    <> word32BE scanBlocksCount
    <> scanBlocks

messageBuilder (FiltersRequestMsg FilterRequestMessage {..}) =
  messageBase FiltersRequest msgSize 
    $  word32BE (currencyCodeToWord32 filterRequestMsgCurrency)
    <> word64BE filterRequestMsgStart
    <> word64BE filterRequestMsgAmount
  where
    msgSize = genericSizeOf (currencyCodeToWord32 filterRequestMsgCurrency)
            + genericSizeOf filterRequestMsgStart
            + genericSizeOf filterRequestMsgAmount

messageBuilder (FiltersResponseMsg FilterResponseMessage {..}) = let
  (filtersSizeSum, filters) = mconcat $ (blockFilterBuilder <$> V.toList filterResponseFilters)
  filtersCount = fromIntegral $ V.length filterResponseFilters
  filtersSize = getSum filtersSizeSum
  zippedFilters = compress $ toLazyByteString filters

  msgSize = genericSizeOf (currencyCodeToWord32 filterResponseCurrency)
          + genericSizeOf filtersCount
          + fromIntegral (LBS.length zippedFilters)
  in messageBase FiltersResponse msgSize
    $  word32BE (currencyCodeToWord32 filterResponseCurrency)
    <> word32BE filtersCount
    <> lazyByteString zippedFilters