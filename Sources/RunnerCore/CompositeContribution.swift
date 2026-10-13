// RunnerCore/CompositeContribution.swift
//
// One student's part of a class composite (docs/class-composite.md): a small
// image, or a short run of frames, that a test script reports in its footer's
// optional `composite` object. RunnerCore only reads and checks the shape; it
// never decodes the pixels, so both runners carry the same base64 text through
// to the server unchanged.

/// The pixel layout of a contribution's decoded bytes.
public enum CompositePixelFormat: String, Sendable, CaseIterable {
    /// One byte per pixel: grey level.
    case gray8
    /// Three bytes per pixel: red, green, blue.
    case rgb8

    /// Bytes per pixel.
    public var channels: Int {
        switch self {
        case .gray8: return 1
        case .rgb8: return 3
        }
    }
}

/// A contribution to a class composite, as a script reported it.
///
/// `data` is the base64 text of `width × height × frames × channels` bytes,
/// frame by frame and row by row. A footer whose `composite` object does not
/// meet every rule in `init?(footer:)` yields no contribution; the test's grade
/// is never affected either way.
public struct CompositeContribution: Equatable, Sendable {
    /// The largest decoded payload a contribution may carry. A composite is
    /// small by design: 48 slots of 30 RGB frames at 8 × 8 is under 6 KB each.
    public static let maxPayloadBytes = 65_536

    public let width: Int
    public let height: Int
    public let frames: Int
    public let format: CompositePixelFormat
    public let data: String

    public init(width: Int, height: Int, frames: Int, format: CompositePixelFormat, data: String) {
        self.width = width
        self.height = height
        self.frames = frames
        self.format = format
        self.data = data
    }

    /// The number of bytes `data` must decode to.
    public var expectedByteCount: Int { width * height * frames * format.channels }

    /// Reads the footer's `composite` object: `w`, `h` and `frames` are
    /// positive whole numbers, `format` is a known pixel format, and `data` is
    /// standard padded base64 of exactly `expectedByteCount` bytes, at most
    /// `maxPayloadBytes`. Any other shape yields nil.
    init?(footer value: FooterValue) {
        guard case .object(let fields) = value,
            let width = Self.positiveInt(fields["w"]),
            let height = Self.positiveInt(fields["h"]),
            let frames = Self.positiveInt(fields["frames"]),
            case .string(let formatName)? = fields["format"],
            let format = CompositePixelFormat(rawValue: formatName),
            case .string(let data)? = fields["data"],
            let byteCount = base64DecodedByteCount(data)
        else { return nil }
        // Each factor is at most `maxPayloadBytes`, so check the product step by
        // step: the full product of four such factors can overflow `Int`.
        let pixels = width.multipliedReportingOverflow(by: height)
        let samples = pixels.partialValue.multipliedReportingOverflow(by: frames)
        guard !pixels.overflow, !samples.overflow,
            samples.partialValue <= Self.maxPayloadBytes,
            samples.partialValue * format.channels == byteCount,
            byteCount <= Self.maxPayloadBytes
        else { return nil }
        self.init(width: width, height: height, frames: frames, format: format, data: data)
    }

    /// A footer number that is a whole number from 1 to `maxPayloadBytes`.
    private static func positiveInt(_ value: FooterValue?) -> Int? {
        guard case .number(let n)? = value, n >= 1, n <= Double(maxPayloadBytes),
            n == n.rounded(.towardZero)
        else { return nil }
        return Int(n)
    }
}

/// The number of bytes that standard padded base64 text decodes to, or nil if
/// the text is not standard padded base64: a length that is a multiple of
/// four, only `A–Z a–z 0–9 + /`, and at most two `=` at the end.
func base64DecodedByteCount(_ text: String) -> Int? {
    let bytes = text.utf8
    guard bytes.count % 4 == 0 else { return nil }
    var padding = 0
    for byte in bytes {
        if byte == UInt8(ascii: "=") {
            padding += 1
        } else if padding > 0 || !isBase64AlphabetByte(byte) {
            // A data character after the padding, or a byte outside the alphabet.
            return nil
        }
    }
    guard padding <= 2 else { return nil }
    return bytes.count / 4 * 3 - padding
}

private func isBase64AlphabetByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
        return true
    default:
        return false
    }
}

// Codable is unavailable in Embedded Swift; only native targets serialize this.
// The keys match the footer and the browser bridge's `JSCompositeContribution`,
// so a browser-posted outcome decodes the same way as a worker-posted one.
#if !hasFeature(Embedded)
extension CompositePixelFormat: Codable {}

extension CompositeContribution: Codable {
    private enum CodingKeys: String, CodingKey {
        case width = "w"
        case height = "h"
        case frames, format, data
    }
}
#endif
