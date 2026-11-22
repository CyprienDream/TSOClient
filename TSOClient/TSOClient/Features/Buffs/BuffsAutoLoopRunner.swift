import Foundation

// Narrow contract BuildingsHandler depends on after every fresh BUILDINGS
// payload. Mirrors SpecialistsAutoLoopRunner. Returning the Task lets tests
// await the dispatch loop without spinning up a real BulkDispatcher delay.
protocol BuffsAutoLoopRunner {
    @discardableResult
    func runAutoBuffSweep() -> Task<Void, Never>?
}

extension BuffDispatchCoordinator: BuffsAutoLoopRunner {}
