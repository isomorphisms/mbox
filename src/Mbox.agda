module Mbox where

open import Data.Bool using (Bool)
open import Data.Fin using (Fin)
open import Data.List using (List)
open import Data.Maybe using (Maybe)
open import Data.Nat using (ℕ; _≤_)
open import Data.String using (String)

-- Raw mail is bytes.  Text decoding is deliberately outside the framing model.
Byte : Set
Byte = Fin 256

ByteOffset : Set
ByteOffset = ℕ

record ByteRange : Set where
  constructor bytes
  field
    start : ByteOffset
    end   : ByteOffset
open ByteRange public

record OrderedRange (r : ByteRange) : Set where
  field
    start≤end : start r ≤ end r

data HeaderDefect : Set where
  malformed-header : ByteRange → HeaderDefect
  orphan-fold      : ByteRange → HeaderDefect

record RawHeaderField : Set where
  constructor header-field
  field
    raw-range       : ByteRange
    name-range      : ByteRange
    name-ascii      : List Byte
    unfolded-value  : List Byte
    defect          : Maybe HeaderDefect
open RawHeaderField public

record MessageView : Set where
  constructor message-view
  field
    envelope-range : ByteRange
    message-range  : ByteRange
    header-range   : ByteRange
    body-range     : ByteRange
    headers        : List RawHeaderField
open MessageView public

record Address : Set where
  constructor mailbox
  field
    display-name : List Byte
    addr-spec    : List Byte
open Address public

record SourceIdentity : Set where
  constructor source
  field
    byte-count : ℕ
    digest     : List Byte
open SourceIdentity public

record Cursor : Set where
  constructor cursor
  field
    source-id : SourceIdentity
    next-byte : ByteOffset
open Cursor public

-- State needed by a chunked mboxo framer.  candidate-prefix contains only the
-- few bytes that may still become a line-leading "From " token.
record Framer : Set where
  constructor framer
  field
    absolute-offset  : ByteOffset
    at-line-start    : Bool
    candidate-prefix : List Byte
    open-envelope    : Maybe ByteRange
    open-message     : Maybe ByteRange
open Framer public

data FrameEvent : Set where
  envelope-begins : ByteOffset → FrameEvent
  message-ends    : ByteOffset → FrameEvent
  framing-defect  : ByteRange → FrameEvent

record FeedResult : Set where
  constructor fed
  field
    state  : Framer
    events : List FrameEvent
open FeedResult public

-- Executable branches must refine this shape:
--
--   feed : Framer → List Byte → FeedResult
--
-- and prove/test that feeding x then y has the same framing result as feeding
-- x ++ y, modulo the intermediate state.  The raw ranges above are the
-- authority; decoded text is not.
--
-- Header and address parsers are separate functions over message/header ranges
-- so MIME/text decoding can never affect mbox boundary discovery.
