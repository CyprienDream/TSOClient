import Foundation

// Swift→JS dispatcher. Views depend on this protocol so the WKWebView seam
// is mockable in tests.
protocol OutboundDispatching {
    func send(_ command: WireCommand)
}
