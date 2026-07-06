import Foundation

// Per-zone state that gets wiped when the player leaves a zone. Each store
// that holds zone-scoped data conforms. GameStateHandler owns a list of
// conformers, so adding a new per-zone store means adding the conformance
// — not editing the handler.
protocol ZoneLifecycle: AnyObject {
    func clear()
}

extension CollectiblesStore:  ZoneLifecycle {}
extension SpecialistsStore:   ZoneLifecycle {}
extension BuildingsStore:     ZoneLifecycle {}
extension BuffsStore:         ZoneLifecycle {}
extension PublicTradesStore:  ZoneLifecycle {}
