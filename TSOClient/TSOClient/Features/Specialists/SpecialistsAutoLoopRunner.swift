import Foundation

// Narrow contract the SpecialistsHandler depends on after every fresh
// SPECIALISTS payload. The handler doesn't need (and shouldn't see) the
// rest of SpecialistDispatchCoordinator's surface — selection state,
// bulk dispatch, defaults persistence, etc.
protocol SpecialistsAutoLoopRunner {
    @discardableResult
    func runAutoExplorerLoop() -> Task<Void, Never>?
    func runAutoGeologistLoop()
}

extension SpecialistDispatchCoordinator: SpecialistsAutoLoopRunner {}
