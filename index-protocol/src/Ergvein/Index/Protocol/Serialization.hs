module Ergvein.Index.Protocol.Serialization where

import Codec.Compression.GZip
import Data.Fixed
import Data.Monoid
import Data.Text.Encoding
import Data.Word
import Foreign.C.Types
import Data.Serialize.Put (Put, runPutLazy, putByteString, putLazyByteString, putWord8, putWord32be,
                          putWord32le, putWord16be, putWord16le, putWord64le)

import Ergvein.Index.Protocol.Types
import Ergvein.Types.Fees
import Ergvein.Types.Currency (Fiat)

import qualified Data.Bitstream as S
import qualified Data.Foldable as F
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as BSS
import qualified Data.Map.Strict as M
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as UV

messageTypeToWord32 :: MessageType -> Word32
messageTypeToWord32 = \case
  MVersionType         -> 0
  MVersionACKType      -> 1
  MFiltersRequestType  -> 2
  MFiltersResponseType -> 3
  MFilterEventType     -> 4
  MPeerRequestType     -> 5
  MPeerResponseType    -> 6
  MFeeRequestType      -> 7
  MFeeResponseType     -> 8
  MIntroducePeerType   -> 9
  MRejectType          -> 10
  MPingType            -> 11
  MPongType            -> 12
  MRatesRequestType    -> 13
  MRatesResponseType   -> 14
  MFullFilterInvType   -> 15
  MGetFullFilterType   -> 16
  MFullFilterType      -> 17
  MGetMemFiltersType   -> 18
  MMemFiltersType      -> 19
  MGetMempoolType      -> 20
  MMempoolChunkType    -> 21

rejectTypeToWord32 :: RejectCode -> Word32
rejectTypeToWord32 = \case
  MessageHeaderParsing -> 0
  MessageParsing       -> 1
  InternalServerError  -> 2
  ZeroBytesReceived    -> 3
  VersionNotSupported  -> 4

feeLevelToWord8 :: FeeLevel -> Word8
feeLevelToWord8 fl = case fl of
  FeeFast     -> 0
  FeeModerate -> 1
  FeeCheap    -> 2

mkProtocolVersion :: ProtocolVersion -> BS.ByteString
mkProtocolVersion (mj,mn,p)
  | mj > 1023 = error $ "Major version out of bounds: " <> show mj <> " should be < 1023"
  | mn > 1023 = error $ "Minor version out of bounds: " <> show mn <> " should be < 1023"
  | p  > 1023 = error $ "Patch version out of bounds: " <> show p  <> " should be < 1023"
  | otherwise = S.toByteString $ w16to10 p <> w16to10 mn <> w16to10 mj <> reservedBits
  where
    w16to10 :: Word16 -> S.Bitstream S.Right
    w16to10 = S.fromNBits (10 :: Int)
    reservedBits :: S.Bitstream S.Right
    reservedBits = S.pack [False, False]

protocolVersionBS :: BS.ByteString
protocolVersionBS = mkProtocolVersion protocolVersion

addressBuilder :: Address -> (Sum Word32, Put)
addressBuilder addr = case addr of
  AddressIpv4 {..} -> (addrSize, putWord8 addrType <> putWord32be addressV4 <> putWord16be addressPort)
  AddressIpv6 {..} -> (addrSize, putWord8 addrType <> encodeIpv6 addressV6 <> putWord16be addressPort)
  AddressOnionV3 {..} -> (addrSize, putWord8 addrType <> putByteString addressOnion <> putWord16be addressPort)
  where
    encodeIpv6 (IpV6 a b c d) = foldMap putWord32be [a, b, c, d]
    addrType = ipTypeToWord8 $ addressType addr
    addrSize = Sum $ genericSizeOf addrType
                   + addressSize (addressType addr)
                   + genericSizeOf (addressPort addr)

varInt :: Integral a => a -> Put
varInt w
  | w < 0xFD = putWord8 $ fromIntegral w
  | w <= 0xFFFF = putWord8 0xFD <> putWord16le (fromIntegral w)
  | w <= 0xFFFFFFFF = putWord8 0xFE <> putWord32le (fromIntegral w)
  | otherwise = putWord8 0xFF <> putWord64le (fromIntegral w)

varIntSize :: Integral a => a -> Word32
varIntSize w
  | w < 0xFD = 1
  | w <= 0xFFFF = 3
  | w <= 0xFFFFFFFF = 5
  | otherwise = 9

messageBase :: MessageType -> Word32 -> Put -> Put
messageBase msgType msgLength payload
  | messageHasPayload msgType = varInt (messageTypeToWord32 msgType) <> varInt msgLength <> payload
  | otherwise = varInt (messageTypeToWord32 msgType)

scanBlockBuilder :: ScanBlock -> (Sum Word32, Put)
scanBlockBuilder ScanBlock {..} = (scanBlockSize, scanBlock)
  where
    currencyCode = currencyCodeToWord32 scanBlockCurrency
    verbs = mkProtocolVersion scanBlockVersion
    scanBlockSize = Sum $ varIntSize currencyCode
                        + (fromIntegral $ BS.length verbs)
                        + varIntSize scanBlockScanHeight
                        + varIntSize scanBlockHeight

    scanBlock = varInt currencyCode
             <> putByteString verbs
             <> varInt scanBlockScanHeight
             <> varInt scanBlockHeight

blockFilterBuilder :: BlockFilter -> (Sum Word32, Put)
blockFilterBuilder BlockFilter {..} = (filterSize, filterBuilder)
  where
    idLength, filterLength :: Word32
    idLength = fromIntegral $ BSS.length blockFilterBlockId
    filterLength = fromIntegral $ BS.length blockFilterFilter
    filterSize = Sum $ idLength
                     + varIntSize filterLength
                     + filterLength
    filterBuilder = putByteString (BSS.fromShort blockFilterBlockId)
                 <> varInt filterLength
                 <> putByteString blockFilterFilter

messageBuilder :: Message -> Put

messageBuilder (MPing msg) = messageBase MPingType msgSize $ putWord64le msg
  where
    msgSize = genericSizeOf msg

messageBuilder (MPong msg) = messageBase MPongType msgSize $ putWord64le msg
  where
    msgSize = genericSizeOf msg

messageBuilder (MReject Reject{..}) = messageBase MRejectType msgSize $
     varInt mid
  <> varInt code
  <> varInt msglen
  <> putByteString msgbs
  where
    mid = messageTypeToWord32 rejectId
    code = rejectTypeToWord32 rejectMsgCode
    msgbs = encodeUtf8 rejectMsg
    msglen = fromIntegral $ BS.length msgbs
    msgSize = varIntSize mid
            + varIntSize code
            + varIntSize msglen
            + msglen

messageBuilder (MVersionACK VersionACK) = messageBase MVersionACKType 0 mempty

messageBuilder (MVersion Version {..}) =
  messageBase MVersionType msgSize
  $  putByteString (mkProtocolVersion versionVersion)
  <> putWord64le (fromIntegral time)
  <> putWord64le versionNonce
  <> varInt scanBlocksCount
  <> scanBlocks
  where
    (scanBlocksSizeSum, scanBlocks) = mconcat $ scanBlockBuilder <$> UV.toList versionScanBlocks
    scanBlocksCount = fromIntegral $ UV.length versionScanBlocks :: Word32
    scanBlocksSize = getSum scanBlocksSizeSum
    msgSize = 4 -- Version is 4-byte long byteString
            + genericSizeOf versionTime
            + genericSizeOf versionNonce
            + varIntSize scanBlocksCount
            + scanBlocksSize
    (CTime time) = versionTime

messageBuilder (MFiltersRequest FilterRequest {..}) =
  messageBase MFiltersRequestType msgSize
  $  varInt currency
  <> varInt filterRequestMsgStart
  <> varInt filterRequestMsgAmount
  where
    currency = currencyCodeToWord32 filterRequestMsgCurrency

    msgSize = varIntSize currency
            + varIntSize filterRequestMsgStart
            + varIntSize filterRequestMsgAmount

messageBuilder (MFiltersResponse FilterResponse {..}) =
  messageBase MFiltersResponseType msgSize
  $  varInt (currencyCodeToWord32 filterResponseCurrency)
  <> varInt filtersCount
  <> putLazyByteString zippedFilters
  where
    (_filtersSizeSum, filters) = foldMap blockFilterBuilder filterResponseFilters
    filtersCount = fromIntegral $ V.length filterResponseFilters :: Word32
    zippedFilters = compress $ runPutLazy filters

    msgSize = varIntSize (currencyCodeToWord32 filterResponseCurrency)
            + varIntSize filtersCount
            + fromIntegral (LBS.length zippedFilters)

messageBuilder (MFiltersEvent FilterEvent {..}) =
  messageBase MFilterEventType msgSize
  $  varInt currency
  <> varInt filterEventHeight
  <> putByteString (BSS.fromShort filterEventBlockId)
  <> varInt filterEventBlockFilterLength
  <> putByteString filterEventBlockFilter
  where
    currency = currencyCodeToWord32 filterEventCurrency
    filterEventBlockIdLength = fromIntegral $ BSS.length filterEventBlockId
    filterEventBlockFilterLength = fromIntegral $ BS.length filterEventBlockFilter

    msgSize = varIntSize currency
            + varIntSize filterEventHeight
            + filterEventBlockIdLength
            + varIntSize filterEventBlockFilterLength
            + filterEventBlockFilterLength

messageBuilder (MFeeRequest curs) = let
  amount = fromIntegral $ length curs :: Word32
  ids = fmap currencyCodeToWord32 curs
  msgSize = varIntSize amount + sum (fmap varIntSize ids)
  msg = varInt amount <> foldMap varInt ids
  in messageBase MFeeRequestType msgSize msg

messageBuilder (MFeeResponse msgs) = let
  amount = fromIntegral $ length msgs :: Word32
  (respSum, resps) = mconcat $ feeRespBuilder <$> msgs
  msgSize = varIntSize amount + getSum respSum
  msg = varInt amount <> resps
  in messageBase MFeeResponseType msgSize msg

messageBuilder (MPeerRequest _) = messageBase MPeerRequestType 0 mempty

messageBuilder (MPeerResponse PeerResponse{..}) = let
  (addressesSize, addresses) = mconcat $ addressBuilder <$> V.toList peerResponseAddresses
  addrAmount = fromIntegral $ V.length peerResponseAddresses :: Word32
  msgSize = varIntSize addrAmount
          + getSum addressesSize
  in messageBase MPeerResponseType msgSize
  $  varInt addrAmount
  <> addresses

messageBuilder (MPeerIntroduce PeerIntroduce{..}) = let
  (addressesSize, addresses) = mconcat $ addressBuilder <$> V.toList peerIntroduceAddresses
  addrAmount = fromIntegral $ V.length peerIntroduceAddresses :: Word32
  msgSize = varIntSize addrAmount
          + getSum addressesSize
  in messageBase MIntroducePeerType msgSize
  $  varInt addrAmount
  <> addresses

messageBuilder (MRatesRequest (RatesRequest rs)) = let
  rsNum = fromIntegral $ length rs :: Word32
  (size, body) = mconcat $ fmap cfBuilder $ M.toList rs
  msgSize = varIntSize rsNum + (getSum size)
  in messageBase MRatesRequestType msgSize $ varInt rsNum <> body
--
messageBuilder (MRatesResponse (RatesResponse rs)) = let
  rsNum = fromIntegral $ length rs :: Word32
  (size, body) = mconcat $ fmap cfdBuilder $ M.toList rs
  msgSize = varIntSize rsNum + getSum size
  in messageBase MRatesResponseType msgSize $ varInt rsNum <> body

messageBuilder (MFullFilterInv FullFilterInv) = messageBase MFullFilterInvType 0 mempty
messageBuilder (MGetFullFilter GetFullFilter) = messageBase MGetFullFilterType 0 mempty
messageBuilder (MGetMemFilters GetMemFilters) = messageBase MGetMemFiltersType 0 mempty

messageBuilder (MFullFilter (MempoolFilter filt)) = let
  (size, body) = lenBsBuilder filt
  in messageBase MFullFilterType (getSum size) body

messageBuilder (MMemFilters msg) = let
  (size, body) = filterTreeBuilder msg
  in messageBase MMemFiltersType (getSum size) body
messageBuilder (MGetMempool (GetMempool ps)) = let
  n = fromIntegral $ length $ ps
  msgSize = varIntSize n + (2 * n)
  msg = varInt n <> foldMap (\(a,b) -> putWord8 a <> putWord8 b) ps
  in messageBase MGetMempoolType msgSize msg
messageBuilder (MMempoolChunk (MempoolChunk (p1, p2) txs)) = let
  txsBs = compress $ runPutLazy $ snd $ F.foldMap lenBsBuilder txs
  len = V.length txs
  lenBs = fromIntegral $ LBS.length txsBs
  msg = putWord8 p1 <> putWord8 p2 <> varInt len <> putLazyByteString txsBs
  msgSize = lenBs + 2 + varIntSize len
  in messageBase MMempoolChunkType msgSize msg

enumBuilder :: Enum a => a -> Put
enumBuilder = varInt . (fromIntegral :: Int -> Word32) . fromEnum

enumSize :: Enum a => a -> Word32
enumSize = (varIntSize :: Word32 -> Word32) . fromIntegral . fromEnum

cfBuilder :: (CurrencyCode, [Fiat]) -> (Sum Word32, Put)
cfBuilder (cc, fs) = let
  fsNum = fromIntegral $ length fs :: Word32
  ccid = currencyCodeToWord32 cc
  size = Sum $ varIntSize ccid + varIntSize fsNum  + sum (fmap enumSize fs)
  in (size, ) $ varInt ccid <> varInt fsNum <> foldMap enumBuilder fs

cfdBuilder :: (CurrencyCode, M.Map Fiat Centi) -> (Sum Word32, Put)
cfdBuilder (cc, fds) = let
  fdsNum = fromIntegral $ length fds :: Word32
  ccid = currencyCodeToWord32 cc
  body = foldMap fdBuilder $ M.toList fds
  size = Sum $ varIntSize ccid + varIntSize fdsNum + sum (fmap fdSize $ M.toList fds)
  in (size, ) $ varInt ccid <> varInt fdsNum <> body

fdSize :: (Fiat, Centi) -> Word32
fdSize (f, _) = enumSize f + 8

fdBuilder :: (Fiat, Centi) -> Put
fdBuilder (f, d) = enumBuilder f <> centiBuilder d

-- | Encode fixed point as 64 bit LE word
centiBuilder :: Centi -> Put
centiBuilder (MkFixed v) = putWord64le $ fromIntegral v

feeRespBuilder :: FeeResp -> (Sum Word32, Put)
feeRespBuilder (FeeRespBTC isTest (FeeBundle (a,b) (c,d) (e,f))) = let
  cur = currencyCodeToWord32 $ if isTest then TBTC else BTC
  vals = [a, b, c, d, e, f]
  msgSize = varIntSize cur + sum (fmap varIntSize vals)
  msg = varInt cur <> foldMap varInt vals
  in (Sum msgSize, msg)

feeRespBuilder (FeeRespGeneric cur h m l) = let
  currency = currencyCodeToWord32 cur
  vals = [h, m, l]
  msgSize = varIntSize currency +  sum (fmap varIntSize vals)
  msg = varInt currency <> foldMap varInt vals
  in (Sum msgSize, msg)

filterTreeBuilder :: FilterTree -> (Sum Word32, Put)
filterTreeBuilder (FilterTree ft) = let
  amount = M.size ft
  (s, ftMsg) = M.foldMapWithKey subBuilder ft
  msg = varInt amount <> ftMsg
  msgSize = s + Sum (varIntSize amount)
  in (msgSize, msg)
  where
    subBuilder :: TxPrefix -> MempoolFilter -> (Sum Word32, Put)
    subBuilder (a,b) mf = let
      (s, mfMsg) = lenBsBuilder $ unMempoolFilter mf
      msg = putWord8 a <> putWord8 b <> mfMsg
      in (s + 2, msg)

lenBsBuilder :: BS.ByteString -> (Sum Word32, Put)
lenBsBuilder bs = let
  len = fromIntegral $ BS.length bs
  msg = varInt len <> putByteString bs
  msgSize = varIntSize len + len
  in (Sum msgSize, msg)
