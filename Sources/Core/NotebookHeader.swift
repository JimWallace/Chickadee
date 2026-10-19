// Core/NotebookHeader.swift
//
// The few top-level facts that callers read from a Jupyter notebook without
// walking its cells: the kernel names in `metadata`, and whether an
// `nbformat` key is present.
//
// A typed decode, not a `[String: Any]` from `JSONSerialization` and not a
// `JSONValue` tree. The decoder reads the fields below and skips the rest, so
// a notebook with large outputs is not built into a value tree only to read
// two strings from it.
//
// Every field is lenient, the same as the `as?` casts it replaced: a field of
// the wrong type reads as absent and does not fail the decode. Only input
// that is not a JSON object fails (`init?(data:)` returns nil).
//
// This is a sniff, not a validity check. The decoder does not check the
// parts that it skips, so a document with invalid JSON in a cell (a raw
// control character in a string, for example) still has a header. A caller
// that must reject invalid JSON uses `JSONSerialization`, as
// `notebookCellCount` does. Two other differences from `JSONSerialization`:
// UTF-32 input with a byte-order mark is not read, and when a key appears
// twice the first value wins, not the last.

public import Foundation

public struct NotebookHeader: Sendable, Equatable {

    /// The kernel names that `metadata` declares.
    public struct Metadata: Sendable, Equatable {
        /// `metadata.kernelspec.name`.
        public var kernelName: String?
        /// `metadata.language_info.name`.
        public var languageInfoName: String?

        public init(kernelName: String?, languageInfoName: String?) {
            self.kernelName = kernelName
            self.languageInfoName = languageInfoName
        }
    }

    /// Nil when the notebook has no `metadata` object.
    public var metadata: Metadata?
    /// True when the top-level object has an `nbformat` key, whatever its value.
    public var hasNBFormatKey: Bool

    /// Reads the header of `data`, or returns nil when `data` is not a JSON
    /// object.
    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(Decoded.self, from: data) else {
            return nil
        }
        self = decoded.header
    }
}

// MARK: - Decoding

extension NotebookHeader {

    /// The decode shape. Kept apart from `NotebookHeader` so that the public
    /// type does not conform to `Decodable`, which would let a caller decode
    /// it with options that this file does not expect.
    private struct Decoded: Decodable {
        let header: NotebookHeader

        private enum Keys: String, CodingKey {
            case metadata, nbformat
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let metadata = try? container.decodeIfPresent(MetadataShape.self, forKey: .metadata)
            header = NotebookHeader(
                metadata: metadata.map {
                    Metadata(kernelName: $0.kernelspec?.name, languageInfoName: $0.languageInfo?.name)
                },
                hasNBFormatKey: container.contains(.nbformat)
            )
        }
    }

    private struct MetadataShape: Decodable {
        let kernelspec: Named?
        let languageInfo: Named?

        private enum Keys: String, CodingKey {
            case kernelspec
            case languageInfo = "language_info"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            kernelspec = try? container.decodeIfPresent(Named.self, forKey: .kernelspec)
            languageInfo = try? container.decodeIfPresent(Named.self, forKey: .languageInfo)
        }
    }

    /// An object whose `name` is read when it is a string.
    private struct Named: Decodable {
        let name: String?

        private enum Keys: String, CodingKey {
            case name
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    private init(metadata: Metadata?, hasNBFormatKey: Bool) {
        self.metadata = metadata
        self.hasNBFormatKey = hasNBFormatKey
    }
}
