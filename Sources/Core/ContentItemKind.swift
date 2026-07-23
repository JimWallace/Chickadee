// Core/ContentItemKind.swift
//
// The kind of an ungraded course content item — a hint for the icon / label
// shown next to the material, not load-bearing for behaviour. A course content
// item (`APICourseContentItem`) is reference material (links, notebooks, slides,
// outlines) that lives inside a course section alongside graded assignments.

public enum ContentItemKind: String, Codable, Sendable, CaseIterable {
    /// A generic external or internal link.
    case link
    /// A Jupyter notebook (lecture / practice), linked rather than hosted.
    case notebook
    /// A document such as a PDF handout.
    case document
    /// Lecture slides.
    case slides
    /// A course outline / syllabus.
    case outline
    /// A structural heading or note with no link payload.
    case heading
}
