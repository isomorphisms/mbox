module Mbox where

open import Data.Bool using (Bool; true; false)
open import Data.Fin using (Fin; toℕ)
open import Data.List using (List; []; _∷_; _++_)
open import Data.Maybe using (Maybe; just; nothing)
open import Data.Nat using (ℕ; _≤_; _∸_)
import Data.Nat as Nat
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

-- candidate-prefix is the undecided beginning of a line.  It is always a
-- prefix of the five octets for "From ".  open-envelope is present only while
-- consuming an envelope line after that prefix has been recognized.
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
  message-begins  : ByteOffset → FrameEvent
  message-ends    : ByteOffset → FrameEvent
  framing-defect  : ByteRange → FrameEvent

record FeedResult : Set where
  constructor fed
  field
    state  : Framer
    events : List FrameEvent
open FeedResult public

-- Compare octets to small ASCII natural numbers without ever decoding the
-- source as text.
nat-equal : ℕ → ℕ → Bool
nat-equal Nat.zero Nat.zero = true
nat-equal Nat.zero (Nat.suc _) = false
nat-equal (Nat.suc _) Nat.zero = false
nat-equal (Nat.suc x) (Nat.suc y) = nat-equal x y

byte-nat-equal : Byte → ℕ → Bool
byte-nat-equal b n = nat-equal (toℕ b) n

from-prefix : List ℕ
from-prefix = 70 ∷ 114 ∷ 111 ∷ 109 ∷ 32 ∷ []

matches-prefix : List Byte → List ℕ → Bool
matches-prefix [] _ = true
matches-prefix (_ ∷ _) [] = false
matches-prefix (b ∷ bs) (n ∷ ns) with byte-nat-equal b n
... | true  = matches-prefix bs ns
... | false = false

matches-whole : List Byte → List ℕ → Bool
matches-whole [] [] = true
matches-whole [] (_ ∷ _) = false
matches-whole (_ ∷ _) [] = false
matches-whole (b ∷ bs) (n ∷ ns) with byte-nat-equal b n
... | true  = matches-whole bs ns
... | false = false

is-lf : Byte → Bool
is-lf b = byte-nat-equal b 10

extend-range : Maybe ByteRange → ByteOffset → Maybe ByteRange
extend-range nothing _ = nothing
extend-range (just r) new-end = just (bytes (start r) new-end)

boundary-events : Maybe ByteRange → ByteOffset → List FrameEvent
boundary-events nothing at = envelope-begins at ∷ []
boundary-events (just _) at = message-ends at ∷ envelope-begins at ∷ []

initial-framer : Framer
initial-framer = framer 0 true [] nothing nothing

-- Consume one octet while an envelope line is already open.  The RFC message
-- begins immediately after LF.  CR in CRLF is just another preserved octet.
step-envelope : Framer → ByteRange → Byte → FeedResult
step-envelope f envelope b with is-lf b
... | true =
  let
    next = Nat.suc (absolute-offset f)
  in
    fed
      (framer next true [] nothing (just (bytes next next)))
      (message-begins next ∷ [])
... | false =
  let
    next = Nat.suc (absolute-offset f)
    envelope′ = bytes (start envelope) next
  in
    fed
      (framer next false [] (just envelope′) (open-message f))
      []

-- Consume one octet outside an envelope line. At a line start, bytes remain
-- undecided only while they are still a prefix of "From ". Keep the nested
-- decisions in named helpers: this makes totality visible to Agda instead of
-- relying on a nested with-clause split whose coverage is easy to misread.
step-candidate-mismatch : Framer → Byte → FeedResult
step-candidate-mismatch f b with is-lf b
... | true =
  let
    next = Nat.suc (absolute-offset f)
  in
    fed
      (framer next true [] nothing (extend-range (open-message f) next))
      []
... | false =
  let
    next = Nat.suc (absolute-offset f)
  in
    fed
      (framer next false [] nothing (extend-range (open-message f) next))
      []

step-candidate-prefix : Framer → Byte → List Byte → FeedResult
step-candidate-prefix f b candidate with matches-whole candidate from-prefix
... | false =
  let
    next = Nat.suc (absolute-offset f)
  in
    fed
      (framer next true candidate nothing (extend-range (open-message f) next))
      []
... | true =
  let
    -- The current octet is the fifth octet in "From ".
    separator-start = absolute-offset f ∸ 4
    next = Nat.suc (absolute-offset f)
  in
    fed
      (framer next false [] (just (bytes separator-start next)) nothing)
      (boundary-events (open-message f) separator-start)

step-candidate : Framer → Byte → List Byte → FeedResult
step-candidate f b candidate with matches-prefix candidate from-prefix
... | false = step-candidate-mismatch f b
... | true  = step-candidate-prefix f b candidate

step-message : Framer → Byte → FeedResult
step-message f b with at-line-start f
... | true =
  step-candidate f b (candidate-prefix f ++ (b ∷ []))
... | false with is-lf b
...   | true =
    let
      next = Nat.suc (absolute-offset f)
    in
      fed
        (framer next true [] nothing (extend-range (open-message f) next))
        []
...   | false =
    let
      next = Nat.suc (absolute-offset f)
    in
      fed
        (framer next false [] nothing (extend-range (open-message f) next))
        []

step : Framer → Byte → FeedResult
step f b with open-envelope f
... | just envelope = step-envelope f envelope b
... | nothing       = step-message f b

-- Incremental framing.  Events are kept in source order.  The function neither
-- decodes headers nor interprets MIME, so chunking cannot affect those layers.
feed : Framer → List Byte → FeedResult
feed f [] = fed f []
feed f (b ∷ bs) with step f b
... | fed f′ first-events with feed f′ bs
...   | fed f″ later-events = fed f″ (first-events ++ later-events)

-- EOF is explicit because feed itself cannot know whether another chunk is
-- coming.  An envelope line terminated by EOF denotes an empty RFC message,
-- matching the non-streaming mboxo interpretation.
finish : Framer → FeedResult
finish f with open-envelope f
... | just _ =
  let
    at = absolute-offset f
  in
    fed
      (framer at true [] nothing nothing)
      (message-begins at ∷ message-ends at ∷ [])
... | nothing with open-message f
...   | just _ =
    let
      at = absolute-offset f
    in
      fed
        (framer at true [] nothing nothing)
        (message-ends at ∷ [])
...   | nothing =
    fed
      (framer (absolute-offset f) true [] nothing nothing)
      []

-- Header and address parsers remain separate functions over message/header
-- ranges.  The next proof obligation is chunking equivalence:
--
-- feeding x and then y must produce exactly the same ordered events and final
-- state as feeding x ++ y, with the events from the two calls concatenated.
-- No postulate should be used for that proof.
