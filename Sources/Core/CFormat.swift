import Foundation

extension String {
    /// `String(format:)` under a name that compiles on every platform.
    ///
    /// The macOS 27 SDK marks Foundation's C-varargs formatter `@unsafe`, so
    /// under strict memory safety each call needs an `unsafe` mark there. On
    /// Linux the same initializer is not unsafe, and an `unsafe` with nothing
    /// unsafe under it is a warning, which `treatAllWarnings` makes an error.
    /// This one place carries the mark only where it applies. The output is
    /// exactly `String(format:)`'s.
    public init(cFormat format: String, _ arguments: any CVarArg...) {
        #if canImport(Darwin)
        self = unsafe String(format: format, arguments: arguments)
        #else
        self = String(format: format, arguments: arguments)
        #endif
    }
}
