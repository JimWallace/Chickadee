// APIServer/Views/PageStyle.swift
//
// A page's private `<style>` block. Elementary escapes text in every element,
// `<style>` included, and a browser does not decode entities inside `<style>`,
// so a child selector `a > b` would reach the page as `a &gt; b` and stop
// matching without an error. The CSS is author-written source, never user
// data, so it goes out raw.

import Elementary

struct PageStyle: HTML {
    let css: String

    init(_ css: StaticString) {
        self.css = css.description
    }

    /// One block from several literals, joined by line breaks; a nil part is
    /// left out. For a page that emits a rule only in one rendering
    /// (`NotebookBody` drops its `.main` override when embedded). Each part is
    /// still a literal, so `scripts/lib/css.sh` reads every one.
    init(_ first: StaticString?, _ rest: StaticString...) {
        self.css = ([first].compactMap { $0 } + rest).map(\.description).joined(separator: "\n")
    }

    var body: some HTML {
        style { HTMLRaw(css) }
    }
}
