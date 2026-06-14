import Foundation

// Fires actions sequentially with a small inter-call delay so rapid
// evaluateJavaScript calls don't get reordered / dropped on the WKWebView
// side, and so each call's outbound auth/seq capture has time to settle
// before the next.
//
// Default delay 80 ms; tests inject a shorter value via init.
struct BulkDispatcher {
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

    // Source-compatibility shim for call sites that don't have an instance
    // injected yet. Uses the default 80 ms delay.
    @discardableResult
    static func run<T>(items: [T], action: @MainActor @escaping (Int, T) -> Void) -> Task<Void, Never> {
        Self.default.run(items: items, action: action)
    }
}
