{-# LANGUAGE RecordWildCards #-}

module Network.HTTP2.Encode (
    encodeFrame
  , encodeFrameHeader
  , encodeFramePayload
  , buildFrame
  , buildFrameHeader
  , buildFramePayload
  , EncodeInfo(..)
  ) where

import Blaze.ByteString.Builder (Builder)
import qualified Blaze.ByteString.Builder as BB
import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Monoid ((<>))

import Network.HTTP2.Types

----------------------------------------------------------------

data EncodeInfo = EncodeInfo {
      encodeFlags    :: FrameFlags
    , encodeStreamId :: StreamIdentifier
    , encodePadding  :: Maybe Padding
    }

----------------------------------------------------------------

encodeFrame :: EncodeInfo -> FramePayload -> ByteString
encodeFrame einfo payload = run $ buildFrame einfo payload

encodeFrameHeader :: FrameTypeId -> FrameHeader -> ByteString
encodeFrameHeader fid header = run $ buildFrameHeader fid header

encodeFramePayload :: EncodeInfo -> FramePayload -> ByteString
encodeFramePayload einfo payload = run payloadBuilder
  where
    (_, (_, payloadBuilder)) = buildFramePayload einfo payload

run :: Builder -> ByteString
run = BL.toStrict . BB.toLazyByteString

----------------------------------------------------------------

buildFrame :: EncodeInfo -> FramePayload -> Builder
buildFrame einfo payload = headerBuilder <> payloadBuilder
  where
    (fid, (header, payloadBuilder)) = buildFramePayload einfo payload
    headerBuilder = buildFrameHeader fid header

----------------------------------------------------------------

buildFrameHeader :: FrameTypeId -> FrameHeader -> Builder
buildFrameHeader fid FrameHeader{..} = len <> typ <> flg <> sid
  where
    -- fixme: 2^14 check
    len1 = BB.fromWord16be (fromIntegral (payloadLength `shiftR` 8))
    len2 = BB.fromWord8 (fromIntegral (payloadLength .&. 0xff))
    len = len1 <> len2
    typ = BB.fromWord8 fid
    flg = BB.fromWord8 flags
    sid = BB.fromWord32be $ fromStreamIdentifier streamId

----------------------------------------------------------------

buildFramePayload :: EncodeInfo -> FramePayload
                  -> (FrameTypeId, (FrameHeader, Builder))
buildFramePayload einfo (DataFrame body) =
    (frameTypeToWord8 FrameData, buildFramePayloadData einfo body)
buildFramePayload einfo (HeadersFrame mpri hdr) =
    (frameTypeToWord8 FrameHeaders, buildFramePayloadHeaders einfo mpri hdr)
buildFramePayload einfo (PriorityFrame pri) =
    (frameTypeToWord8 FramePriority, buildFramePayloadPriority einfo pri)
buildFramePayload einfo (RSTStreamFrame e) =
    (frameTypeToWord8 FrameRSTStream, buildFramePayloadRSTStream einfo e)
buildFramePayload einfo (SettingsFrame settings) =
    (frameTypeToWord8 FrameSettings, buildFramePayloadSettings einfo settings)
buildFramePayload einfo (PushPromiseFrame sid hdr) =
    (frameTypeToWord8 FramePushPromise, buildFramePayloadPushPromise einfo sid hdr)
buildFramePayload einfo (PingFrame odata) =
    (frameTypeToWord8 FramePing, buildFramePayloadPing einfo odata)
buildFramePayload einfo (GoAwayFrame sid e debug) =
    (frameTypeToWord8 FrameGoAway, buildFramePayloadGoAway einfo sid e debug)
buildFramePayload einfo (WindowUpdateFrame size) =
    (frameTypeToWord8 FrameWindowUpdate, buildFramePayloadWindowUpdate einfo size)
buildFramePayload einfo (ContinuationFrame hdr) =
    (frameTypeToWord8 FrameContinuation, buildFramePayloadContinuation einfo hdr)
buildFramePayload _einfo (UnknownFrame _ _) = undefined

----------------------------------------------------------------

buildPadding :: EncodeInfo -> Builder -> PayloadLength -> (FrameHeader, Builder)
buildPadding EncodeInfo{ encodePadding = Nothing, ..} builder len =
    (header, builder)
  where
    header = FrameHeader len encodeFlags encodeStreamId
buildPadding EncodeInfo{ encodePadding = Just padding, ..} btarget targetLength =
    (header, builder)
  where
    header = FrameHeader len newflags encodeStreamId
    builder = bpadlen <> btarget <> bpadding
    bpadlen = BB.fromWord8 $ fromIntegral paddingLength
    bpadding = BB.fromByteString padding
    paddingLength = B.length padding
    len = targetLength + paddingLength + 1
    newflags = setPadded encodeFlags

buildPriority :: Priority -> Builder
buildPriority Priority{..} = builder
  where
    builder = bstream <> bweight
    stream = fromStreamIdentifier streamDependency
    estream
      | exclusive = setExclusive stream
      | otherwise = stream
    bstream = BB.fromWord32be estream
    bweight = BB.fromWord8 $ fromIntegral $ weight - 1

-- fixme: clear 31th bit?
buildStream :: StreamIdentifier -> Builder
buildStream = BB.fromWord32be . fromStreamIdentifier

buildErrorCode :: ErrorCode -> Builder
buildErrorCode = BB.fromWord32be . errorCodeToWord32

----------------------------------------------------------------

buildFramePayloadData :: EncodeInfo -> ByteString -> (FrameHeader, Builder)
buildFramePayloadData einfo body = buildPadding einfo builder len
  where
    builder = BB.fromByteString body
    len = B.length body

buildFramePayloadHeaders :: EncodeInfo -> Maybe Priority -> HeaderBlockFragment
                         -> (FrameHeader, Builder)
buildFramePayloadHeaders einfo Nothing hdr =
    buildPadding einfo builder len
  where
    builder = BB.fromByteString hdr
    len = B.length hdr
buildFramePayloadHeaders einfo (Just pri) hdr =
    buildPadding einfo builder len
  where
    builder = buildPriority pri <> BB.fromByteString hdr
    len = B.length hdr + 5

buildFramePayloadPriority :: EncodeInfo -> Priority -> (FrameHeader, Builder)
buildFramePayloadPriority EncodeInfo{..} p = (header, builder)
  where
    builder = buildPriority p
    header = FrameHeader 5 encodeFlags encodeStreamId

buildFramePayloadRSTStream :: EncodeInfo -> ErrorCode -> (FrameHeader, Builder)
buildFramePayloadRSTStream EncodeInfo{..} e = (header, builder)
  where
    builder = buildErrorCode e
    header = FrameHeader 4 encodeFlags encodeStreamId

buildFramePayloadSettings :: EncodeInfo -> Settings -> (FrameHeader, Builder)
buildFramePayloadSettings _einfo _settings = undefined

buildFramePayloadPushPromise :: EncodeInfo -> StreamIdentifier -> HeaderBlockFragment -> (FrameHeader, Builder)
buildFramePayloadPushPromise einfo sid hdr = buildPadding einfo builder len
  where
    builder = buildStream sid <> BB.fromByteString hdr
    len = 4 + B.length hdr

buildFramePayloadPing :: EncodeInfo -> ByteString -> (FrameHeader, Builder)
buildFramePayloadPing EncodeInfo{..} odata = (header, builder)
  where
    builder = BB.fromByteString odata
    header = FrameHeader 8 encodeFlags encodeStreamId

buildFramePayloadGoAway :: EncodeInfo -> LastStreamId -> ErrorCode -> ByteString -> (FrameHeader, Builder)
buildFramePayloadGoAway EncodeInfo{..} sid e debug = (header, builder)
  where
    builder = buildStream sid <> buildErrorCode e <> BB.fromByteString debug
    len = 4 + 4 + B.length debug
    header = FrameHeader len encodeFlags encodeStreamId

buildFramePayloadWindowUpdate :: EncodeInfo -> WindowSizeIncrement -> (FrameHeader, Builder)
buildFramePayloadWindowUpdate EncodeInfo{..} size = (header, builder)
  where
    -- fixme: reserve bit
    builder = BB.fromWord32be size
    header = FrameHeader 4 encodeFlags encodeStreamId

buildFramePayloadContinuation :: EncodeInfo -> HeaderBlockFragment -> (FrameHeader, Builder)
buildFramePayloadContinuation EncodeInfo{..} hdr = (header, builder)
  where
    builder = BB.fromByteString hdr
    len = B.length hdr
    header = FrameHeader len encodeFlags encodeStreamId
