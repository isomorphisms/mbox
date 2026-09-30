# RFC-shaped semantic model for Idriç mail

This note is a design gate for the Idriç branch. It is intentionally about the
shape of the standards before it is about parser code.

## 1. No untyped mail bytes above the I/O boundary

The operating system supplies octets. That is an implementation boundary, not
the semantic vocabulary of the library.

A source octet may initially be represented by `Bits8`, but once the parser
recognizes structure it should refine that source into RFC-named values. A mail
body that the current layer deliberately does not interpret is still a semantic
`MessageBody` or `RawBody`, with a source range, rather than an arbitrary
list of bytes.

Every parsed value retains a source span so the original message can be copied
without regeneration.

## 2. Mirror RFC 5322 grammar

The first semantic vocabulary should follow the named ABNF productions instead
of inventing one generic header representation.

Examples of types that should exist as their own values include:

    CRLF
    FWS
    CFWS
    Comment
    QuotedPair
    Atext
    Atom
    DotAtomText
    DotAtom
    Qtext
    QuotedString
    Word
    Phrase
    Unstructured

    LocalPart
    Domain
    DomainLiteral
    AddrSpec
    AngleAddr
    NameAddr
    Mailbox
    MailboxList
    Group
    Address
    AddressList

    DayOfWeek
    Day
    Month
    Year
    TimeOfDay
    Zone
    Date
    Time
    DateTime

    MessageId
    References
    InReplyTo

Obsolete productions in section 4 are not "anything goes". They should be
represented explicitly as obsolete syntax so a caller can distinguish modern
syntax from tolerated historical input.

## 3. Header section and individual fields are different types

Follow the RFC's distinction between the header section and a header field.

The core field family should be typed by meaning, for example:

    OriginationDateField
    FromField
    SenderField
    ReplyToField
    ToField
    CcField
    BccField
    MessageIdField
    InReplyToField
    ReferencesField
    SubjectField
    CommentsField
    KeywordsField

    ResentDateField
    ResentFromField
    ResentSenderField
    ResentToField
    ResentCcField
    ResentBccField
    ResentMessageIdField

    ReturnPathField
    ReceivedField

RFC 6854 changes the legal semantic content of From, Sender, Resent-From, and
Resent-Sender. That update belongs in those types rather than as an ad hoc
parser exception.

Multiplicity and ordering constraints belong in the semantic structure where
practical. Trace and resent blocks should not be flattened into an unordered
map.

## 4. Registered extension fields remain typed

The IANA Message Headers registry is the namespace authority for extension
field names. A field that has not yet received a full value parser should still
be represented as something like:

    RegisteredField reference registered_name source_body

rather than being demoted to an untyped string.

Unregistered fields likewise need an explicit `UnregisteredField` type with
their legal field name and source body. Unknown is a semantic state.

Common registered families should acquire value types from their defining RFCs:
MIME fields, List-* fields, Auto-Submitted, DKIM-Signature,
Authentication-Results, ARC fields, Received-SPF, Archived-At, and so on.

## 5. MIME is a second grammar, not "header text"

RFCs 2045, 2046, 2047, 2183, and 2231 add semantic objects including:

    MimeVersion
    MediaType
    MediaSubtype
    MediaParameter
    ContentType
    ContentTransferEncoding
    ContentId
    ContentDescription
    EncodedWord
    ContentDisposition
    DispositionParameter

The IANA media-type registry provides the changing vocabulary of registered
media types. The parser should preserve an extension media type even when no
specialized payload decoder exists.

## 6. Internationalized mail is explicit

RFCs 6530-6533 and the downgrade work in RFC 6857 are not reasons to turn the
whole parser into "Unicode strings".

ASCII-only RFC productions remain ASCII-only types. UTF-8-enabled productions
receive their own widened types where the standards allow them. The source
representation remains exact.

## 7. mbox is a container around RFC messages

RFC 4155 describes application/mbox and its default format. The repository's
v0 contract can deliberately choose a particular mbox variant, but that choice
must be stated as a relationship to RFC 4155 rather than treated as the
definition of Internet message syntax.

An mbox envelope separator is not the RFC 5322 `From:` field. Give the two
different types.

## 8. Defects are values, not booleans

Replace a generic `malformed : Bool` direction with defect types that say
which grammar or invariant failed and where. Recovery must preserve source
material and must not pretend recovered input was valid RFC syntax.

## 9. Promotion into Idriç / Edriç

The mail repository is the forcing example. Pieces that are genuinely general
should later move into Idriç/Edriç itself: source spans, exact slices,
incremental input, ABNF-shaped parsing support, ASCII classes, UTF-8 validation,
and typed refinement from raw input.

Mail-specific grammar remains a mail library. The language should make the RFC
look natural; it should not hard-code electronic mail into the compiler.
