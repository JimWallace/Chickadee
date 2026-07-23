// Core/ContentLink.swift
//
// One labelled link on a course content item. A single content item may carry
// several — e.g. "Lecture 1 (PDF | Jupyter Notebook)" is one item with two links
// — matching how a course materials page lists multiple formats for one row.

public struct ContentLink: Codable, Sendable, Equatable {
    /// Short label for the link, e.g. "PDF" or "Jupyter Notebook".
    public let label: String
    /// The link target: an absolute http(s) URL, or a site-relative path.
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}
