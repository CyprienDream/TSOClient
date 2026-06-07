import Foundation

// Fires actions sequentially with a small inter-call delay so rapid
// evaluateJavaScript calls don't get reordered / dropped on the WKWebView
// side, and so each call's outbound auth/seq capture has time to settle
// before the next.
enum BulkDispatcher {
    static let interCallDelayNs: UInt64 = 80_000_000  // 80 ms

    static func run<T>(items: [T], action: @MainActor @escaping (Int, T) -> Void) {
        Task { @MainActor in
            for (i, item) in items.enumerated() {
                action(i, item)
                try? await Task.sleep(nanoseconds: interCallDelayNs)
            }
        }
    }
}
