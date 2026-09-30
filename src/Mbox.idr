module Mbox

import Data.Bits
import Data.List

%default total

public export
ByteOffset : Type
ByteOffset = Integer

public export
record ByteRange where
  constructor Bytes
  start : ByteOffset
  end   : ByteOffset

public export
data HeaderDefect
  = MalformedHeader ByteRange
  | OrphanFold ByteRange

public export
record RawHeaderField where
  constructor HeaderField
  rawRange      : ByteRange
  nameRange     : ByteRange
  nameAscii     : List Bits8
  unfoldedValue : List Bits8
  defect        : Maybe HeaderDefect

public export
record MessageView where
  constructor Message
  envelopeRange : ByteRange
  messageRange  : ByteRange
  headerRange   : ByteRange
  bodyRange     : ByteRange
  headers       : List RawHeaderField

public export
record Address where
  constructor Mailbox
  displayName : List Bits8
  addrSpec    : List Bits8

public export
record SourceIdentity where
  constructor Source
  byteCount : Integer
  digest    : List Bits8

public export
record Cursor where
  constructor At
  sourceId : SourceIdentity
  nextByte : ByteOffset

public export
record Framer where
  constructor Framing
  absoluteOffset  : ByteOffset
  atLineStart     : Bool
  candidatePrefix : List Bits8
  openEnvelope    : Maybe ByteRange
  openMessage     : Maybe ByteRange

public export
data FrameEvent
  = EnvelopeBegins ByteOffset
  | MessageEnds ByteOffset
  | FramingDefect ByteRange

public export
record FeedResult where
  constructor Fed
  state  : Framer
  events : List FrameEvent

fromPrefix : List Bits8
fromPrefix = [70, 114, 111, 109, 32]

prefix : Eq a => List a -> List a -> Bool
prefix [] _ = True
prefix (_ :: _) [] = False
prefix (x :: xs) (y :: ys) = x == y && prefix xs ys

public export
isEnvelopeStart : Bool -> List Bits8 -> Bool
isEnvelopeStart False _ = False
isEnvelopeStart True bytes = prefix fromPrefix bytes

public export
initialFramer : Framer
initialFramer = Framing 0 True [] Nothing Nothing

asciiLower : Bits8 -> Bits8
asciiLower b =
  if b >= 65 && b <= 90
     then b + 32
     else b

public export
asciiCaseEqual : List Bits8 -> List Bits8 -> Bool
asciiCaseEqual [] [] = True
asciiCaseEqual [] (_ :: _) = False
asciiCaseEqual (_ :: _) [] = False
asciiCaseEqual (x :: xs) (y :: ys) =
  asciiLower x == asciiLower y && asciiCaseEqual xs ys

findAt : Bits8 -> List Bits8 -> Maybe Integer
findAt wanted = go 0
  where
    go : Integer -> List Bits8 -> Maybe Integer
    go _ [] = Nothing
    go n (x :: xs) =
      if x == wanted
         then Just n
         else go (n + 1) xs

takeI : Integer -> List a -> List a
takeI n xs = take (cast n) xs

dropI : Integer -> List a -> List a
dropI n xs = drop (cast n) xs

public export
addrSpecDomainFoldEqual : List Bits8 -> List Bits8 -> Bool
addrSpecDomainFoldEqual a b =
  case (findAt 64 a, findAt 64 b) of
    (Just ai, Just bi) =>
      takeI ai a == takeI bi b &&
      asciiCaseEqual (dropI (ai + 1) a) (dropI (bi + 1) b)
    _ => a == b

-- The executable framing function is deliberately the next boundary:
--
--   feed : Framer -> List Bits8 -> FeedResult
--
-- It must retain no more than the undecided line-leading "From " candidate
-- plus the currently open entry state, and it must satisfy the chunking
-- equivalence in CONTRACT.md.  This branch does not use String as a shortcut:
-- raw mail remains Bits8 throughout the framing model.
