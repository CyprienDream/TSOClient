import Foundation

// High-level specialist classification. The raw values match the strings the
// JS scanner emits in the SPECIALISTS payload's `specialistType` field; an
// unrecognised raw value decodes to `.unknown` instead of throwing.
enum SpecialistKind: String, CaseIterable, Hashable, Codable {
    case explorer  = "Explorer"
    case geologist = "Geologist"
    case general   = "General"
    case unknown   = "Unknown"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpecialistKind(rawValue: raw) ?? .unknown
    }
}
