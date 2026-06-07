import Foundation

extension String {
    // "PirateExplorer" → "Pirate Explorer". Inserts a space before each
    // uppercase character after the first. Empty input returns empty.
    var camelCaseToWords: String {
        var out = ""
        for (i, ch) in self.enumerated() {
            if i > 0 && ch.isUppercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}
