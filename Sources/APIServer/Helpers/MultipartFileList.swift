// APIServer/Helpers/MultipartFileList.swift
//
// One Decodable wrapper for the "many files OR one bare file" multipart
// quirk: most browsers post a repeated `suiteFiles[]` field that decodes as
// `[File]`, but Safari posts a single selection as one bare `File`.
// Historically every form body needed a Many/Single struct pair differing
// only in `suiteFiles: [File]?` vs `File?`; this type collapses each pair
// into one struct with `var suiteFiles: MultipartFileList?`.

import Vapor

/// Decodes either an array of multipart `File`s or a single bare `File`
/// (wrapped into a one-element array), so form bodies need only one decode
/// path for both shapes.
struct MultipartFileList: Codable {
    /// The decoded files; a single bare file becomes a one-element array.
    var files: [File]

    init(files: [File]) {
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([File].self) {
            self.files = many
        } else {
            self.files = [try container.decode(File.self)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(files)
    }
}
