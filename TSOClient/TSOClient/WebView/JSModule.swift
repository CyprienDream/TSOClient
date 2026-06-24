import Foundation

// A single injected JS module. `preProcess` runs after the file is loaded
// from the bundle and before the source is handed to WKUserScript, so
// per-module substitutions (e.g. the collectible patcher's hash list)
// don't need a special case in JSInjection.install.
struct JSModule {
    let name: String
    let preProcess: ((String) -> String)?

    init(_ name: String, preProcess: ((String) -> String)? = nil) {
        self.name = name
        self.preProcess = preProcess
    }
}
