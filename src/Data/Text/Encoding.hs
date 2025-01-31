{-# LANGUAGE BangPatterns, CPP, GeneralizedNewtypeDeriving, MagicHash,
    UnliftedFFITypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TypeApplications #-}
-- |
-- Module      : Data.Text.Encoding
-- Copyright   : (c) 2009, 2010, 2011 Bryan O'Sullivan,
--               (c) 2009 Duncan Coutts,
--               (c) 2008, 2009 Tom Harper
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Portability : portable
--
-- Functions for converting 'Text' values to and from 'ByteString',
-- using several standard encodings.
--
-- To gain access to a much larger family of encodings, use the
-- <http://hackage.haskell.org/package/text-icu text-icu package>.

module Data.Text.Encoding
    (
    -- * Decoding ByteStrings to Text
    -- $strict
      decodeASCII
    , decodeLatin1
    , decodeUtf8
    , decodeUtf16LE
    , decodeUtf16BE
    , decodeUtf32LE
    , decodeUtf32BE

    -- ** Catchable failure
    , decodeUtf8'

    -- ** Controllable error handling
    , decodeUtf8With
    , decodeUtf8Lenient
    , decodeUtf16LEWith
    , decodeUtf16BEWith
    , decodeUtf32LEWith
    , decodeUtf32BEWith

    -- ** Stream oriented decoding
    -- $stream
    , streamDecodeUtf8
    , streamDecodeUtf8With
    , Decoding(..)

    -- * Encoding Text to ByteStrings
    , encodeUtf8
    , encodeUtf16LE
    , encodeUtf16BE
    , encodeUtf32LE
    , encodeUtf32BE

    -- * Encoding Text using ByteString Builders
    , encodeUtf8Builder
    , encodeUtf8BuilderEscaped
    ) where

import Control.Monad.ST.Unsafe (unsafeIOToST, unsafeSTToIO)

import Control.Exception (evaluate, try, throwIO, ErrorCall(ErrorCall))
import Control.Monad.ST (runST)
import Data.Bits ((.&.), shiftR)
import Data.ByteString as B
import qualified Data.ByteString.Internal as B
import Data.Foldable (traverse_)
import Data.Text.Encoding.Error (OnDecodeError, UnicodeException, strictDecode, lenientDecode)
import Data.Text.Internal (Text(..), safe, text)
import Data.Text.Internal.Functions
import Data.Text.Internal.Private (runText)
import Data.Text.Internal.Unsafe.Char (ord, unsafeWrite)
import Data.Text.Show ()
import Data.Text.Unsafe (unsafeDupablePerformIO)
import Data.Word (Word8, Word16, Word32)
import Foreign.C.Types (CSize(CSize))
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, minusPtr, nullPtr, plusPtr)
import Foreign.Storable (Storable, peek, poke)
import GHC.Base (ByteArray#, MutableByteArray#)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Builder.Internal as B hiding (empty, append)
import qualified Data.ByteString.Builder.Prim as BP
import qualified Data.ByteString.Builder.Prim.Internal as BP
import qualified Data.Text.Array as A
import qualified Data.Text.Internal.Encoding.Fusion as E
import qualified Data.Text.Internal.Encoding.Utf16 as U16
import qualified Data.Text.Internal.Fusion as F
import Data.Text.Internal.ByteStringCompat
#if defined(ASSERTS)
import GHC.Stack (HasCallStack)
#endif

#include "text_cbits.h"

-- $strict
--
-- All of the single-parameter functions for decoding bytestrings
-- encoded in one of the Unicode Transformation Formats (UTF) operate
-- in a /strict/ mode: each will throw an exception if given invalid
-- input.
--
-- Each function has a variant, whose name is suffixed with -'With',
-- that gives greater control over the handling of decoding errors.
-- For instance, 'decodeUtf8' will throw an exception, but
-- 'decodeUtf8With' allows the programmer to determine what to do on a
-- decoding error.

-- | /Deprecated/.  Decode a 'ByteString' containing 7-bit ASCII
-- encoded text.
decodeASCII :: ByteString -> Text
decodeASCII = decodeUtf8
{-# DEPRECATED decodeASCII "Use decodeUtf8 instead" #-}

-- | Decode a 'ByteString' containing Latin-1 (aka ISO-8859-1) encoded text.
--
-- 'decodeLatin1' is semantically equivalent to
--  @Data.Text.pack . Data.ByteString.Char8.unpack@
decodeLatin1 ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Text
decodeLatin1 bs = withBS bs aux where
  aux fp len = text a 0 len
   where
    a = A.run (A.new len >>= unsafeIOToST . go)
    go dest = unsafeWithForeignPtr fp $ \ptr -> do
      c_decode_latin1 (A.maBA dest) ptr (ptr `plusPtr` len)
      return dest

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- __NOTE__: The replacement character returned by 'OnDecodeError'
-- MUST be within the BMP plane; surrogate code points will
-- automatically be remapped to the replacement char @U+FFFD@
-- (/since 0.11.3.0/), whereas code points beyond the BMP will throw an
-- 'error' (/since 1.2.3.1/); For earlier versions of @text@ using
-- those unsupported code points would result in undefined behavior.
decodeUtf8With ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  OnDecodeError -> ByteString -> Text
decodeUtf8With onErr bs = withBS bs aux
 where
  aux fp len = runText $ \done -> do
    let go dest = unsafeWithForeignPtr fp $ \ptr ->
          with (0::CSize) $ \destOffPtr -> do
            let end = ptr `plusPtr` len
                loop curPtr = do
                  curPtr' <- c_decode_utf8 (A.maBA dest) destOffPtr curPtr end
                  if curPtr' == end
                    then do
                      n <- peek destOffPtr
                      unsafeSTToIO (done dest (cSizeToInt n))
                    else do
                      x <- peek curPtr'
                      case onErr desc (Just x) of
                        Nothing -> loop $ curPtr' `plusPtr` 1
                        Just c
                          | c > '\xFFFF' -> throwUnsupportedReplChar
                          | otherwise -> do
                              destOff <- peek destOffPtr
                              w <- unsafeSTToIO $
                                   unsafeWrite dest (cSizeToInt destOff)
                                               (safe c)
                              poke destOffPtr (destOff + intToCSize w)
                              loop $ curPtr' `plusPtr` 1
            loop ptr
    (unsafeIOToST . go) =<< A.new len
   where
    desc = "Data.Text.Internal.Encoding.decodeUtf8: Invalid UTF-8 stream"

    throwUnsupportedReplChar = throwIO $
      ErrorCall "decodeUtf8With: non-BMP replacement characters not supported"
  -- TODO: The code currently assumes that the transcoded UTF-16
  -- stream is at most twice as long (in bytes) as the input UTF-8
  -- stream. To justify this assumption one has to assume that the
  -- error handler replacement character also satisfies this
  -- invariant, by emitting at most one UTF16 code unit.
  --
  -- One easy way to support the full range of code-points for
  -- replacement characters in the error handler is to simply change
  -- the (over-)allocation to `A.new (2*len)` and then shrink back the
  -- `ByteArray#` to the real size (recent GHCs have a cheap
  -- `ByteArray#` resize-primop for that which allow the GC to reclaim
  -- the overallocation). However, this would require 4 times as much
  -- (temporary) storage as the original UTF-8 required.
  --
  -- Another strategy would be to optimistically assume that
  -- replacement characters are within the BMP, and if the case of a
  -- non-BMP replacement occurs reallocate the target buffer (or throw
  -- an exception, and fallback to a pessimistic codepath, like e.g.
  -- `decodeUtf8With onErr bs = F.unstream (E.streamUtf8 onErr bs)`)
  --
  -- Alternatively, `OnDecodeError` could become a datastructure which
  -- statically encodes the replacement-character range,
  -- e.g. something isomorphic to
  --
  --   Either (... -> Maybe Word16) (... -> Maybe Char)
  --
  -- And allow to statically switch between the BMP/non-BMP
  -- replacement-character codepaths. There's multiple ways to address
  -- this with different tradeoffs; but ideally we should optimise for
  -- the optimistic/error-free case.
{- INLINE[0] decodeUtf8With #-}

-- $stream
--
-- The 'streamDecodeUtf8' and 'streamDecodeUtf8With' functions accept
-- a 'ByteString' that represents a possibly incomplete input (e.g. a
-- packet from a network stream) that may not end on a UTF-8 boundary.
--
-- 1. The maximal prefix of 'Text' that could be decoded from the
--    given input.
--
-- 2. The suffix of the 'ByteString' that could not be decoded due to
--    insufficient input.
--
-- 3. A function that accepts another 'ByteString'.  That string will
--    be assumed to directly follow the string that was passed as
--    input to the original function, and it will in turn be decoded.
--
-- To help understand the use of these functions, consider the Unicode
-- string @\"hi &#9731;\"@. If encoded as UTF-8, this becomes @\"hi
-- \\xe2\\x98\\x83\"@; the final @\'&#9731;\'@ is encoded as 3 bytes.
--
-- Now suppose that we receive this encoded string as 3 packets that
-- are split up on untidy boundaries: @[\"hi \\xe2\", \"\\x98\",
-- \"\\x83\"]@. We cannot decode the entire Unicode string until we
-- have received all three packets, but we would like to make progress
-- as we receive each one.
--
-- @
-- ghci> let s0\@('Some' _ _ f0) = 'streamDecodeUtf8' \"hi \\xe2\"
-- ghci> s0
-- 'Some' \"hi \" \"\\xe2\" _
-- @
--
-- We use the continuation @f0@ to decode our second packet.
--
-- @
-- ghci> let s1\@('Some' _ _ f1) = f0 \"\\x98\"
-- ghci> s1
-- 'Some' \"\" \"\\xe2\\x98\"
-- @
--
-- We could not give @f0@ enough input to decode anything, so it
-- returned an empty string. Once we feed our second continuation @f1@
-- the last byte of input, it will make progress.
--
-- @
-- ghci> let s2\@('Some' _ _ f2) = f1 \"\\x83\"
-- ghci> s2
-- 'Some' \"\\x2603\" \"\" _
-- @
--
-- If given invalid input, an exception will be thrown by the function
-- or continuation where it is encountered.

-- | A stream oriented decoding result.
--
-- @since 1.0.0.0
data Decoding = Some Text ByteString (ByteString -> Decoding)

instance Show Decoding where
    showsPrec d (Some t bs _) = showParen (d > prec) $
                                showString "Some " . showsPrec prec' t .
                                showChar ' ' . showsPrec prec' bs .
                                showString " _"
      where prec = 10; prec' = prec + 1

newtype CodePoint = CodePoint Word32 deriving (Eq, Show, Num, Storable)
newtype DecoderState = DecoderState Word32 deriving (Eq, Show, Num, Storable)

-- | Decode, in a stream oriented way, a 'ByteString' containing UTF-8
-- encoded text that is known to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown (either by this function or a continuation) that cannot be
-- caught in pure code.  For more control over the handling of invalid
-- data, use 'streamDecodeUtf8With'.
--
-- @since 1.0.0.0
streamDecodeUtf8 ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Decoding
streamDecodeUtf8 = streamDecodeUtf8With strictDecode

-- | Decode, in a stream oriented way, a lazy 'ByteString' containing UTF-8
-- encoded text.
--
-- @since 1.0.0.0
streamDecodeUtf8With ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  OnDecodeError -> ByteString -> Decoding
streamDecodeUtf8With onErr = decodeChunk B.empty 0 0
 where
  -- We create a slightly larger than necessary buffer to accommodate a
  -- potential surrogate pair started in the last buffer (@undecoded0@), or
  -- replacement characters for each byte in @undecoded0@ if the
  -- sequence turns out to be invalid. There can be up to three bytes there,
  -- hence we allocate @len+3@ 16-bit words.
  decodeChunk :: ByteString -> CodePoint -> DecoderState -> ByteString
              -> Decoding
  decodeChunk undecoded0 codepoint0 state0 bs = withBS bs aux where
    aux fp len = runST $ (unsafeIOToST . decodeChunkToBuffer) =<< A.new (len+3)
       where
        decodeChunkToBuffer :: A.MArray s -> IO Decoding
        decodeChunkToBuffer dest = unsafeWithForeignPtr fp $ \ptr ->
          with (0::CSize) $ \destOffPtr ->
          with codepoint0 $ \codepointPtr ->
          with state0 $ \statePtr ->
          with nullPtr $ \curPtrPtr ->
            let end = ptr `plusPtr` len
                loop curPtr = do
                  prevState <- peek statePtr
                  poke curPtrPtr curPtr
                  lastPtr <- c_decode_utf8_with_state (A.maBA dest) destOffPtr
                             curPtrPtr end codepointPtr statePtr
                  state <- peek statePtr
                  case state of
                    UTF8_REJECT -> do
                      -- We encountered an encoding error
                      poke statePtr 0
                      let skipByte x = case onErr desc (Just x) of
                            Nothing -> return ()
                            Just c -> do
                              destOff <- peek destOffPtr
                              w <- unsafeSTToIO $
                                   unsafeWrite dest (cSizeToInt destOff) (safe c)
                              poke destOffPtr (destOff + intToCSize w)
                      if ptr == lastPtr && prevState /= UTF8_ACCEPT then do
                        -- If we can't complete the sequence @undecoded0@ from
                        -- the previous chunk, we invalidate the bytes from
                        -- @undecoded0@ and retry decoding the current chunk from
                        -- the initial state.
                        traverse_ skipByte (B.unpack undecoded0 )
                        loop lastPtr
                      else do
                        peek lastPtr >>= skipByte
                        loop (lastPtr `plusPtr` 1)

                    _ -> do
                      -- We encountered the end of the buffer while decoding
                      n <- peek destOffPtr
                      codepoint <- peek codepointPtr
                      chunkText <- unsafeSTToIO $ do
                          arr <- A.unsafeFreeze dest
                          return $! text arr 0 (cSizeToInt n)
                      let left = lastPtr `minusPtr` ptr
                          !undecoded = case state of
                            UTF8_ACCEPT -> B.empty
                            _ | left == 0 && prevState /= UTF8_ACCEPT -> B.append undecoded0 bs
                              | otherwise -> B.drop left bs
                      return $ Some chunkText undecoded
                               (decodeChunk undecoded codepoint state)
            in loop ptr
  desc = "Data.Text.Internal.Encoding.streamDecodeUtf8With: Invalid UTF-8 stream"

-- | Decode a 'ByteString' containing UTF-8 encoded text that is known
-- to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown that cannot be caught in pure code.  For more control over
-- the handling of invalid data, use 'decodeUtf8'' or
-- 'decodeUtf8With'.
decodeUtf8 :: ByteString -> Text
decodeUtf8 = decodeUtf8With strictDecode
{-# INLINE[0] decodeUtf8 #-}
{-# RULES "STREAM stream/decodeUtf8 fusion" [1]
    forall bs. F.stream (decodeUtf8 bs) = E.streamUtf8 strictDecode bs #-}

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- If the input contains any invalid UTF-8 data, the relevant
-- exception will be returned, otherwise the decoded text.
decodeUtf8' ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Either UnicodeException Text
decodeUtf8' = unsafeDupablePerformIO . try . evaluate . decodeUtf8With strictDecode
{-# INLINE decodeUtf8' #-}

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- Any invalid input bytes will be replaced with the Unicode replacement
-- character U+FFFD.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = decodeUtf8With lenientDecode

-- | Encode text to a ByteString 'B.Builder' using UTF-8 encoding.
--
-- @since 1.1.0.0
encodeUtf8Builder :: Text -> B.Builder
encodeUtf8Builder = encodeUtf8BuilderEscaped (BP.liftFixedToBounded BP.word8)

-- | Encode text using UTF-8 encoding and escape the ASCII characters using
-- a 'BP.BoundedPrim'.
--
-- Use this function is to implement efficient encoders for text-based formats
-- like JSON or HTML.
--
-- @since 1.1.0.0
{-# INLINE encodeUtf8BuilderEscaped #-}
-- TODO: Extend documentation with references to source code in @blaze-html@
-- or @aeson@ that uses this function.
encodeUtf8BuilderEscaped :: BP.BoundedPrim Word8 -> Text -> B.Builder
encodeUtf8BuilderEscaped be =
    -- manual eta-expansion to ensure inlining works as expected
    \txt -> B.builder (mkBuildstep txt)
  where
    bound = max 4 $ BP.sizeBound be

    mkBuildstep (Text arr off len) !k =
        outerLoop off
      where
        iend = off + len

        outerLoop !i0 !br@(B.BufferRange op0 ope)
          | i0 >= iend       = k br
          | outRemaining > 0 = goPartial (i0 + min outRemaining inpRemaining)
          -- TODO: Use a loop with an integrated bound's check if outRemaining
          -- is smaller than 8, as this will save on divisions.
          | otherwise        = return $ B.bufferFull bound op0 (outerLoop i0)
          where
            outRemaining = (ope `minusPtr` op0) `div` bound
            inpRemaining = iend - i0

            goPartial !iendTmp = go i0 op0
              where
                go !i !op
                  | i < iendTmp = case A.unsafeIndex arr i of
                      w | w <= 0x7F -> do
                            BP.runB be (word16ToWord8 w) op >>= go (i + 1)
                        | w <= 0x7FF -> do
                            poke8 @Word16 0 $ (w `shiftR` 6) + 0xC0
                            poke8 @Word16 1 $ (w .&. 0x3f) + 0x80
                            go (i + 1) (op `plusPtr` 2)
                        | 0xD800 <= w && w <= 0xDBFF -> do
                            let c = ord $ U16.chr2 w (A.unsafeIndex arr (i+1))
                            poke8 @Int 0 $ (c `shiftR` 18) + 0xF0
                            poke8 @Int 1 $ ((c `shiftR` 12) .&. 0x3F) + 0x80
                            poke8 @Int 2 $ ((c `shiftR` 6) .&. 0x3F) + 0x80
                            poke8 @Int 3 $ (c .&. 0x3F) + 0x80
                            go (i + 2) (op `plusPtr` 4)
                        | otherwise -> do
                            poke8 @Word16 0 $ (w `shiftR` 12) + 0xE0
                            poke8 @Word16 1 $ ((w `shiftR` 6) .&. 0x3F) + 0x80
                            poke8 @Word16 2 $ (w .&. 0x3F) + 0x80
                            go (i + 1) (op `plusPtr` 3)
                  | otherwise =
                      outerLoop i (B.BufferRange op ope)
                  where
                    -- Take care, a is either Word16 or Int above
                    poke8 :: Integral a => Int -> a -> IO ()
                    poke8 j v = poke (op `plusPtr` j) (fromIntegral v :: Word8)

-- | Encode text using UTF-8 encoding.
encodeUtf8 :: Text -> ByteString
encodeUtf8 (Text arr off len)
  | len == 0  = B.empty
  | otherwise = unsafeDupablePerformIO $ do
  fp <- B.mallocByteString (len*3) -- see https://github.com/haskell/text/issues/194 for why len*3 is enough
  unsafeWithForeignPtr fp $ \ptr ->
    with ptr $ \destPtr -> do
      c_encode_utf8 destPtr (A.aBA arr) (intToCSize off) (intToCSize len)
      newDest <- peek destPtr
      let utf8len = newDest `minusPtr` ptr
      if utf8len >= len `shiftR` 1
        then return (mkBS fp utf8len)
        else do
          fp' <- B.mallocByteString utf8len
          unsafeWithForeignPtr fp' $ \ptr' -> do
            B.memcpy ptr' ptr utf8len
            return (mkBS fp' utf8len)

-- | Decode text from little endian UTF-16 encoding.
decodeUtf16LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16LEWith onErr bs = F.unstream (E.streamUtf16LE onErr bs)
{-# INLINE decodeUtf16LEWith #-}

-- | Decode text from little endian UTF-16 encoding.
--
-- If the input contains any invalid little endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16LEWith'.
decodeUtf16LE :: ByteString -> Text
decodeUtf16LE = decodeUtf16LEWith strictDecode
{-# INLINE decodeUtf16LE #-}

-- | Decode text from big endian UTF-16 encoding.
decodeUtf16BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16BEWith onErr bs = F.unstream (E.streamUtf16BE onErr bs)
{-# INLINE decodeUtf16BEWith #-}

-- | Decode text from big endian UTF-16 encoding.
--
-- If the input contains any invalid big endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16BEWith'.
decodeUtf16BE :: ByteString -> Text
decodeUtf16BE = decodeUtf16BEWith strictDecode
{-# INLINE decodeUtf16BE #-}

-- | Encode text using little endian UTF-16 encoding.
encodeUtf16LE :: Text -> ByteString
encodeUtf16LE txt = E.unstream (E.restreamUtf16LE (F.stream txt))
{-# INLINE encodeUtf16LE #-}

-- | Encode text using big endian UTF-16 encoding.
encodeUtf16BE :: Text -> ByteString
encodeUtf16BE txt = E.unstream (E.restreamUtf16BE (F.stream txt))
{-# INLINE encodeUtf16BE #-}

-- | Decode text from little endian UTF-32 encoding.
decodeUtf32LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32LEWith onErr bs = F.unstream (E.streamUtf32LE onErr bs)
{-# INLINE decodeUtf32LEWith #-}

-- | Decode text from little endian UTF-32 encoding.
--
-- If the input contains any invalid little endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32LEWith'.
decodeUtf32LE :: ByteString -> Text
decodeUtf32LE = decodeUtf32LEWith strictDecode
{-# INLINE decodeUtf32LE #-}

-- | Decode text from big endian UTF-32 encoding.
decodeUtf32BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32BEWith onErr bs = F.unstream (E.streamUtf32BE onErr bs)
{-# INLINE decodeUtf32BEWith #-}

-- | Decode text from big endian UTF-32 encoding.
--
-- If the input contains any invalid big endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32BEWith'.
decodeUtf32BE :: ByteString -> Text
decodeUtf32BE = decodeUtf32BEWith strictDecode
{-# INLINE decodeUtf32BE #-}

-- | Encode text using little endian UTF-32 encoding.
encodeUtf32LE :: Text -> ByteString
encodeUtf32LE txt = E.unstream (E.restreamUtf32LE (F.stream txt))
{-# INLINE encodeUtf32LE #-}

-- | Encode text using big endian UTF-32 encoding.
encodeUtf32BE :: Text -> ByteString
encodeUtf32BE txt = E.unstream (E.restreamUtf32BE (F.stream txt))
{-# INLINE encodeUtf32BE #-}

cSizeToInt :: CSize -> Int
cSizeToInt = fromIntegral

intToCSize :: Int -> CSize
intToCSize = fromIntegral

word16ToWord8 :: Word16 -> Word8
word16ToWord8 = fromIntegral

foreign import ccall unsafe "_hs_text_decode_utf8" c_decode_utf8
    :: MutableByteArray# s -> Ptr CSize
    -> Ptr Word8 -> Ptr Word8 -> IO (Ptr Word8)

foreign import ccall unsafe "_hs_text_decode_utf8_state" c_decode_utf8_with_state
    :: MutableByteArray# s -> Ptr CSize
    -> Ptr (Ptr Word8) -> Ptr Word8
    -> Ptr CodePoint -> Ptr DecoderState -> IO (Ptr Word8)

foreign import ccall unsafe "_hs_text_decode_latin1" c_decode_latin1
    :: MutableByteArray# s -> Ptr Word8 -> Ptr Word8 -> IO ()

foreign import ccall unsafe "_hs_text_encode_utf8" c_encode_utf8
    :: Ptr (Ptr Word8) -> ByteArray# -> CSize -> CSize -> IO ()
