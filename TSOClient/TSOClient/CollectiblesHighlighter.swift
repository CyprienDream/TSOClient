import WebKit
import AppKit

// The list of image filenames the game uses for collectible items.
// These are the asset names the game requests from the CDN.
let collectibleAssetPatterns = [
    "collectible",
    "collect_",
    "sammelitem",
    "pickup_item",
    "loot_"
]

// A custom URL scheme handler that intercepts asset requests
// and overlays a glowing highlight on collectible images.
class HighlightSchemeHandler: NSObject, WKURLSchemeHandler {

    // Called when WebKit starts a resource load matching our scheme
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let originalURL = originalURL(from: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Fetch the original asset from the CDN
        URLSession.shared.dataTask(with: originalURL) { data, response, error in
            if let error = error {
                urlSchemeTask.didFailWithError(error)
                return
            }
            guard let data = data, let response = response else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }

            // If this is a collectible, draw a glow over it
            let finalData = self.isCollectibleURL(originalURL)
                ? self.addGlow(to: data) ?? data
                : data

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(finalData)
            urlSchemeTask.didFinish()
        }.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    // Convert our intercept scheme back to https so we can fetch the real asset
    private func originalURL(from interceptURL: URL) -> URL? {
        var components = URLComponents(url: interceptURL, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    private func isCollectibleURL(_ url: URL) -> Bool {
        let path = url.absoluteString.lowercased()
        return collectibleAssetPatterns.contains { path.contains($0) }
    }

    // Draw a glowing pink/yellow halo around the image
    private func addGlow(to data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let padding: CGFloat = 12
        let newSize = NSSize(width: size.width + padding * 2,
                             height: size.height + padding * 2)

        let result = NSImage(size: newSize)
        result.lockFocus()

        // Draw glowing halo (multiple passes for a soft glow effect)
        let glowColors: [(NSColor, CGFloat)] = [
            (NSColor.systemYellow.withAlphaComponent(0.25), 10),
            (NSColor.systemYellow.withAlphaComponent(0.45), 6),
            (NSColor.white.withAlphaComponent(0.6), 3)
        ]

        for (color, radius) in glowColors {
            let glowImage = NSImage(size: newSize)
            glowImage.lockFocus()
            image.draw(in: NSRect(x: padding, y: padding,
                                  width: size.width, height: size.height))
            glowImage.unlockFocus()

            if let cgImage = glowImage.cgImage(forProposedRect: nil,
                                                context: nil, hints: nil) {
                let ciImage = CIImage(cgImage: cgImage)
                let filter = CIFilter(name: "CIGaussianBlur")!
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(radius, forKey: kCIInputRadiusKey)

                if let output = filter.outputImage {
                    let rep = NSCIImageRep(ciImage: output)
                    let blurred = NSImage(size: newSize)
                    blurred.addRepresentation(rep)

                    color.setFill()
                    NSRect(origin: .zero, size: newSize).fill(using: .sourceAtop)
                    blurred.draw(in: NSRect(origin: .zero, size: newSize),
                                 from: .zero, operation: .screen, fraction: 1.0)
                }
            }
        }

        // Draw original image on top of glow
        image.draw(in: NSRect(x: padding, y: padding,
                               width: size.width, height: size.height))

        result.unlockFocus()

        return result.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .png, properties: [:]) }
    }
}
