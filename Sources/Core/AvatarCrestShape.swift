// Core/AvatarCrestShape.swift
//
// The crest a crested species wears, chosen by the tuft slot
// (docs/avatar-species.md, "Trait map").

/// The three shapes a crest takes. A crested species draws one from the tuft
/// slot: `none` and `swoop` are swept, `crest` and `pair` raised, `cowlick`
/// relaxed. So a stored tuft keeps rendering, as a crest, on a crested bird.
public enum AvatarCrestShape: String, CaseIterable, Sendable {
    case swept, raised, relaxed

    public init(tuft: AvatarTuft) {
        switch tuft {
        case .none, .swoop: self = .swept
        case .crest, .pair: self = .raised
        case .cowlick: self = .relaxed
        }
    }
}
