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

    var body: some HTML {
        style { HTMLRaw(css) }
    }
}
