import Foundation

// Thin seam over Bundle.main so registries (NamingRegistry, BuffCategoryClassifier,
// etc.) can be loaded from synthetic data in tests without touching the file system.
protocol ResourceLoader {
    func loadData(name: String, ext: String) -> Data?
}

struct BundleResourceLoader: ResourceLoader {
    let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func loadData(name: String, ext: String) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }
}
