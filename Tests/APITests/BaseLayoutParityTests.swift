// Tests/APITests/BaseLayoutParityTests.swift
//
// While Leaf pages and Elementary pages are both served, `base.leaf` and
// `BaseLayout` must load the same scripts and stylesheets, declare the same
// meta tags and link to the same places. A head script or a nav entry added to
// one and not the other would reach only half the pages, with no error
// (docs/elementary-spike.md, "Guards"). Delete this suite with `base.leaf`.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import APIServer

@Suite struct BaseLayoutParityTests {

    /// Every attribute value that names a path, a fragment or a meta tag.
    private static var attribute: Regex<(Substring, Substring, Substring)> { /(src|href|action|name)="([^"]*)"/ }

    /// The values `base.leaf` writes, with the version query dropped. A value
    /// built from a Leaf interpolation becomes a pattern for its rendered form.
    private static func leafValues() throws -> (fixed: Set<String>, patterns: [Regex<AnyRegexOutput>]) {
        let url = repositoryRoot.appendingPathComponent("Resources/Views/base.leaf")
        let markup = LeafMarkupScanner.strippingHTMLComments(try String(contentsOf: url, encoding: .utf8))
        var fixed: Set<String> = []
        var patterns: [Regex<AnyRegexOutput>] = []
        for match in markup.matches(of: attribute) {
            let value = withoutVersionQuery(String(match.2))
            if value.contains("#(") || value.contains("#csrf") {
                let escaped = NSRegularExpression.escapedPattern(for: value)
                let pattern = escaped.replacing(/#\\\(.*?\\\)/, with: "[^/\"]+")
                patterns.append(try Regex("^" + pattern + "$"))
            } else {
                fixed.insert(String(match.1) + "=" + value)
            }
        }
        // The CSRF field tag renders a hidden input named `_csrf`.
        if markup.contains("#csrfFormField(") {
            fixed.insert("name=_csrf")
        }
        return (fixed, patterns)
    }

    /// The values the Elementary layout renders across its branches: signed
    /// out, staff in one course, staff in two (menu and tab strip), with
    /// in-place forms.
    private static func layoutValues() -> Set<String> {
        let oneCourse = CurrentUserContext(
            user: APIUser(username: "one", passwordHash: "", role: UserRole.user.rawValue),
            activeCourse: nil,
            enrolledCourses: [
                CourseContext(
                    id: "c1", code: "CS135", name: "Design", isActive: true, role: .instructor, urlKey: "CS135")
            ])
        let pages = [
            ElementaryPageFixtures.page(currentUser: nil),
            ElementaryPageFixtures.page(currentUser: oneCourse),
            ElementaryPageFixtures.page(currentUser: ElementaryPageFixtures.signedInAdmin),
        ]
        var values: Set<String> = []
        for page in pages {
            let html = BaseLayout(title: "T", page: page, inPlaceForms: true) { "" }.render()
            for match in html.matches(of: attribute) {
                values.insert(String(match.1) + "=" + withoutVersionQuery(String(match.2)))
            }
        }
        return values
    }

    private static func withoutVersionQuery(_ value: String) -> String {
        value.replacing(/\?v=.*$/, with: "")
    }

    @Test func bothLayoutsLoadTheSameAssetsAndLinks() throws {
        let leaf = try Self.leafValues()
        #expect(leaf.fixed.count > 10, "the base.leaf scan found too little, so it is broken")
        #expect(!leaf.patterns.isEmpty, "the base.leaf scan found no interpolated value, so it is broken")

        let rendered = Self.layoutValues()
        let renderedFixed = rendered.filter { value in
            let path = String(value.drop { $0 != "=" }.dropFirst())
            return !leaf.patterns.contains { path.wholeMatch(of: $0) != nil }
        }

        let missingFromLayout = leaf.fixed.subtracting(renderedFixed).sorted()
        let missingFromLeaf = renderedFixed.subtracting(leaf.fixed).sorted()
        #expect(missingFromLayout.isEmpty, "base.leaf has, BaseLayout lacks: \(missingFromLayout)")
        #expect(missingFromLeaf.isEmpty, "BaseLayout has, base.leaf lacks: \(missingFromLeaf)")
    }
}
