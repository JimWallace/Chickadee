// Core/NotebookCellView.swift
//
// The fields of a notebook cell that the read-only cell walkers use: the cell
// type, the source, the cell id and the metadata tags. A typed decode, not a
// `[[String: Any]]` from `JSONSerialization`.
//
// The decoder reads these fields and skips the rest of each cell, most of all
// the outputs, which are the large part of a notebook. Measured on a 2.8 MB
// notebook: 0.07 s, where `JSONSerialization` took 0.25 s and a full
// `JSONValue` decode 0.7 s.
//
// The same rules as the `as?` casts that it replaces: a field of the wrong
// type reads as absent, and `cells(from:)` returns nil unless `cells` is an
// array of objects. Like `NotebookHeader`, this is a read, not a validity
// check: the decoder does not check the parts that it skips, so a validity
// gate must not use it. Two other differences from `JSONSerialization`:
// UTF-32 input with a byte-order mark is not read, and when a key appears
// twice the first value wins, not the last.

public import Foundation

public struct NotebookCellView: Sendable, Equatable {
    /// `cell_type`, or nil when it is absent or not a string.
    public var cellType: String?
    /// `source` as one string: a string as it is, an array of strings joined.
    /// Empty when `source` is absent, of another type, or an array with an
    /// element that is not a string (the rule of `NotebookCellSources.cellSource`).
    public var source: String
    /// `id`, or nil when it is absent or not a string.
    public var id: String?
    /// `metadata.tags`, or nil when it is absent or not an array of strings.
    public var tags: [String]?

    public init(cellType: String?, source: String, id: String? = nil, tags: [String]? = nil) {
        self.cellType = cellType
        self.source = source
        self.id = id
        self.tags = tags
    }

    /// The cells of the notebook in `data`, or nil when `data` is not a JSON
    /// object whose `cells` is an array of objects.
    public static func cells(from data: Data) -> [NotebookCellView]? {
        (try? JSONDecoder().decode(NotebookShape.self, from: data))?.cells.map(\.view)
    }
}

// MARK: - Decoding

extension NotebookCellView {

    private struct NotebookShape: Decodable {
        let cells: [CellShape]
    }

    private struct CellShape: Decodable {
        let view: NotebookCellView

        private enum Keys: String, CodingKey {
            case cellType = "cell_type"
            case source, id, metadata
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let source = try? container.decodeIfPresent(SourceShape.self, forKey: .source)
            let metadata = try? container.decodeIfPresent(MetadataShape.self, forKey: .metadata)
            view = NotebookCellView(
                cellType: try? container.decodeIfPresent(String.self, forKey: .cellType),
                source: source?.text ?? "",
                id: try? container.decodeIfPresent(String.self, forKey: .id),
                tags: metadata?.tags)
        }
    }

    /// A string, or an array of strings to join.
    private struct SourceShape: Decodable {
        let text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self.text = text
            } else {
                text = try container.decode([String].self).joined()
            }
        }
    }

    private struct MetadataShape: Decodable {
        let tags: [String]?

        private enum Keys: String, CodingKey {
            case tags
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            tags = try? container.decodeIfPresent([String].self, forKey: .tags)
        }
    }
}
