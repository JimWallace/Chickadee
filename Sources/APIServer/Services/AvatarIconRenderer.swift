// APIServer/Services/AvatarIconRenderer.swift
//
// One bird as a standalone SVG document: the browser tab icon
// (docs/student-avatars.md, "The tab icon").
//
// A page draws a bird with use elements against the inline avatar sprite, and
// the stylesheet colours it through custom properties. A favicon is a document
// of its own, so it can use neither. This renderer reads the two files that own
// the art once, at boot: the symbol children from
// Resources/Sprites/avatar-sprite.svg, and the palette values and the av-*
// class rules from Public/styles.css. It copies them into one self-contained
// document per bird. It holds no path and no colour of its own, so the tab and
// the page cannot draw two different birds.
//
// The icon leaves out two things the page draws. The ring takes the outer
// 1.5px at 16px and blurs into the backdrop. The tilt goes too, so the bird
// sits upright in the tab. The palette is the light one: the backdrop disc
// fills the whole viewBox, so one file reads on a light and a dark tab bar.

import Core
import Foundation

/// Why the renderer could not be built. Each is a startup error: an icon
/// with a missing part would be a blank or wrong bird, and nothing would fail.
enum AvatarIconRendererError: Error, Equatable, CustomStringConvertible {
    /// A symbol some bird names is not in the sprite.
    case missingSymbol(String)
    /// A symbol does not draw in the 64x64 box the icon uses.
    case unexpectedViewBox(symbol: String, viewBox: String)
    /// A sprite class has no `.av-*` rule in the stylesheet.
    case missingClassRule(String)
    /// A custom property a rule or a bird names has no value.
    case missingToken(String)
    /// The stylesheet has no light `:root` block.
    case missingPalette

    var description: String {
        switch self {
        case .missingSymbol(let id): "avatar icon: the sprite has no symbol \(id)"
        case .unexpectedViewBox(let id, let viewBox): "avatar icon: symbol \(id) has viewBox \(viewBox), not 0 0 64 64"
        case .missingClassRule(let name): "avatar icon: the stylesheet has no rule for .\(name)"
        case .missingToken(let name): "avatar icon: the stylesheet gives no value for \(name)"
        case .missingPalette: "avatar icon: the stylesheet has no light :root block"
        }
    }
}

struct AvatarIconRenderer: Sendable {
    /// One symbol's children, on one line, and the classes they use.
    private struct Layer: Sendable {
        let markup: String
        let classes: [String]
    }

    private let layers: [String: Layer]
    /// Class name to its declarations, compacted. Palette references are
    /// already resolved; the per-bird `--av-*` references are left for `svg(for:)`.
    private let classRules: [String: String]
    /// Every `--avatar-*` value in the light `:root` block.
    private let palette: [String: String]

    /// Reads the sprite and the stylesheet, and checks that every symbol,
    /// class and token any bird can name is there.
    init(sprite: String, stylesheet: String) throws(AvatarIconRendererError) {
        let palette = try Self.parsePalette(stylesheet)
        let symbols = Self.parseSymbols(sprite)
        let rawRules = Self.parseClassRules(stylesheet)
        let birdProperties = Set(Self.sample.inlineProperties.map(\.name))

        var layers: [String: Layer] = [:]
        var classRules: [String: String] = [:]
        for ref in Self.nameableLayerRefs {
            let id = String(ref.dropFirst())
            guard let symbol = symbols[id] else { throw AvatarIconRendererError.missingSymbol(id) }
            guard symbol.viewBox == "0 0 64 64" else {
                throw AvatarIconRendererError.unexpectedViewBox(symbol: id, viewBox: symbol.viewBox)
            }
            let layer = Self.layer(from: symbol.content)
            for name in layer.classes where classRules[name] == nil {
                guard let declarations = rawRules[name] else { throw AvatarIconRendererError.missingClassRule(name) }
                classRules[name] = try Self.resolve(declarations, palette: palette, birdProperties: birdProperties)
            }
            layers[ref] = layer
        }
        for token in Self.nameableTokens where palette[token] == nil {
            throw AvatarIconRendererError.missingToken(token)
        }
        self.layers = layers
        self.classRules = classRules
        self.palette = palette
    }

    /// The bird as an SVG document. Every part it names was checked at boot.
    func svg(for spec: AvatarSpec) -> String {
        let presentation = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
        let drawn = Self.iconLayerRefs(of: presentation).compactMap { layers[$0] }

        var classes: [String] = []
        for name in drawn.flatMap(\.classes) where !classes.contains(name) {
            classes.append(name)
        }
        let rules = classes.compactMap { name in
            classRules[name].map { ".\(name){\(bind($0, to: presentation))}" }
        }
        return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">"#
            + "<style>\(rules.joined())</style>"
            + drawn.map(\.markup).joined()
            + "</svg>"
    }

    /// Replaces each per-bird `var(--av-*)` with this bird's palette value.
    private func bind(_ declarations: String, to presentation: AvatarPresentation) -> String {
        presentation.inlineProperties.reduce(declarations) { result, property in
            guard let value = palette[property.token] else { return result }
            return result.replacing("var(\(property.name))", with: value)
        }
    }

    // MARK: - What a bird can name

    /// The layers an icon draws, back to front: the page's layers without the ring.
    private static func iconLayerRefs(of presentation: AvatarPresentation) -> [String] {
        presentation.layerRefs.filter { $0 != presentation.ringSymbolRef }
    }

    /// Any bird. Only its custom-property names are read, and those are the
    /// same for every bird.
    private static let sample = AvatarPresentation(
        for: AvatarIconKey.houseSpec, size: .standard, accessibility: .decorative, isStaff: false)

    /// Every layer any icon can draw. The expression does not change which
    /// tuft, plumage, wing or accessory a bird draws, so it is enumerated apart.
    private static var nameableLayerRefs: Set<String> {
        var refs: Set<String> = []
        for cap in AvatarCap.allCases {
            for wing in AvatarWing.allCases {
                for tuft in AvatarTuft.allCases {
                    for accessory in AvatarAccessory.allCases {
                        let spec = AvatarSpec(
                            cap: cap, wing: wing, expression: .bright, accessory: accessory,
                            accent: .ember, backdrop: .sky, tuft: tuft)
                        refs.formUnion(iconLayerRefs(of: presentation(for: spec)))
                    }
                }
            }
        }
        for expression in AvatarExpression.allCases {
            var spec = AvatarIconKey.houseSpec
            spec.expression = expression
            refs.formUnion(iconLayerRefs(of: presentation(for: spec)))
        }
        return refs
    }

    /// Every palette token any icon can name.
    static var nameableTokens: Set<String> {
        var tokens: Set<String> = []
        for cap in AvatarCap.allCases {
            for accent in AvatarAccent.allCases {
                for backdrop in AvatarBackdrop.allCases {
                    let spec = AvatarSpec(
                        cap: cap, wing: .plain, expression: .bright, accessory: .none,
                        accent: accent, backdrop: backdrop)
                    tokens.formUnion(presentation(for: spec).tokens)
                }
            }
        }
        return tokens
    }

    private static func presentation(for spec: AvatarSpec) -> AvatarPresentation {
        AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: false)
    }

    // MARK: - Parsing

    /// The `--avatar-*` declarations of the first `:root` block, which is the
    /// light one. The dark blocks come later and are not read.
    private static func parsePalette(_ css: String) throws(AvatarIconRendererError) -> [String: String] {
        guard let start = css.firstRange(of: ":root {"),
            let end = css[start.upperBound...].firstRange(of: "\n}")
        else { throw AvatarIconRendererError.missingPalette }
        var palette: [String: String] = [:]
        for match in css[start.upperBound..<end.lowerBound].matches(of: /(--avatar-[a-z0-9-]+):\s*([^;]+);/) {
            palette[String(match.1)] = String(match.2).trimmingCharacters(in: .whitespaces)
        }
        guard !palette.isEmpty else { throw AvatarIconRendererError.missingPalette }
        return palette
    }

    /// The one-line `.av-* { … }` rules that colour the sprite's classes.
    private static func parseClassRules(_ css: String) -> [String: String] {
        var rules: [String: String] = [:]
        for match in css.matches(of: /^\.(av-[a-z0-9-]+) \{([^}]*)\}/.anchorsMatchLineEndings()) {
            rules[String(match.1)] = String(match.2)
        }
        return rules
    }

    private static func parseSymbols(_ sprite: String) -> [String: (viewBox: String, content: String)] {
        var symbols: [String: (viewBox: String, content: String)] = [:]
        let pattern = /<symbol id="([^"]+)" viewBox="([^"]+)">(.*?)<\/symbol>/.dotMatchesNewlines()
        for match in sprite.matches(of: pattern) {
            symbols[String(match.1)] = (String(match.2), String(match.3))
        }
        return symbols
    }

    private static func layer(from content: String) -> Layer {
        let markup = content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        var classes: [String] = []
        for match in markup.matches(of: /class="([^"]+)"/) {
            for name in match.1.split(separator: " ").map(String.init) where !classes.contains(name) {
                classes.append(name)
            }
        }
        return Layer(markup: markup, classes: classes)
    }

    /// Compacts a rule's declarations and resolves its palette references. A
    /// per-bird reference stays, and must be one the presentation assigns.
    private static func resolve(
        _ declarations: String, palette: [String: String], birdProperties: Set<String>
    ) throws(AvatarIconRendererError) -> String {
        var result = declarations.split(separator: ";")
            .map { $0.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.count == 2 }
            .map { "\($0[0]):\($0[1])" }
            .joined(separator: ";")
        for match in result.matches(of: /var\((--[a-z0-9-]+)\)/) {
            let name = String(match.1)
            if birdProperties.contains(name) { continue }
            guard let value = palette[name] else { throw AvatarIconRendererError.missingToken(name) }
            result = result.replacing("var(\(name))", with: value)
        }
        return result
    }
}
