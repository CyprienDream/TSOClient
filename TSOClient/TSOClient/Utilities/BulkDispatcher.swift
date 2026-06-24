import Foundation

// Fires actions sequentially with a small inter-call delay so rapid
// evaluateJavaScript calls don't get reordered / dropped on the WKWebView
// side, and so each call's outbound auth/seq capture has time to settle
// before the next.
//
// Coordinators depend on the BulkDispatching protocol so tests can
// substitute a zero-delay fake runner without sleeping through the
// production 80 ms gap.
protocol BulkDispatching {
    @discardableResult
    func run<T>(items: [T], action: @MainActor @escaping (Int, T) -> Void) -> Task<Void, Never>
}

struct BulkDispatcher: BulkDispatching {
    let interCallDelayNs: UInt64

    init(interCallDelayNs: UInt64 = 80_000_000) {
        self.interCallDelayNs = interCallDelayNs
    }

    static let `default` = BulkDispatcher()

    // Returned Task lets tests await completion; production call sites can
    // discard it (@discardableResult).
    @discardableResult
    func run<T>(items: [T], action: @MainActor @escaping (Int, T) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            for (i, item) in items.enumerated() {
                action(i, item)
                try? await Task.sleep(nanoseconds: interCallDelayNs)
            }
        }
    }
}
