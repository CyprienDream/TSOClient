import Foundation

// Strips the trailing "_NN" variant suffix from a raw building skin
// (e.g. "Woodcutter_01" -> "Woodcutter"). Owned independently of
// BuildingsStore so the rule has a single home and the regex is
// compiled once at init.
struct BuildingSkinNormalizer {
    private let suffix: NSRegularExpression

    init() {
        self.suffix = try! NSRegularExpression(pattern: #"_\d+$"#)
    }

    static let `default` = BuildingSkinNormalizer()

    func base(of skin: String) -> String {
        let range = NSRange(skin.startIndex..., in: skin)
        return suffix.stringByReplacingMatches(in: skin, range: range, withTemplate: "")
    }
}
