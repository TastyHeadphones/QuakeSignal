import Foundation

/// Looks up `key` in Localizable.strings and substitutes `args` positionally.
/// Use this (rather than SwiftUI's `Text("literal \(interpolation)")` sugar)
/// whenever the lookup key itself is a stable symbolic identifier like
/// "quake.intensity.label" -- SwiftUI's interpolation sugar folds the
/// arguments into the *key*, which only works when the key is the literal
/// English sentence. These keys must also stay in sync with the loc-key
/// pairs the backend uses for APNs (see backend/src/push/payload.ts).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

enum AppEnvironment {
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
