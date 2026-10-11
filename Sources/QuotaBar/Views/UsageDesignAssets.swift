import AppKit
import CoreText
import SwiftUI

@MainActor
enum UsageDesignAssets {
    private static let fontName = "PPNeueMachina-InktrapRegular"

    // SwiftPM's generated accessor supports development builds. Packaged apps
    // keep the same resource bundle in their standard Resources directory.
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QuotaBar_QuotaBar.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    private static let hasBundledFont: Bool = {
        guard let url = resourceBundle.url(forResource: fontName, withExtension: "otf") else {
            return false
        }
        // Optional for licensed local previews. Public builds use system fonts.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return NSFont(name: fontName, size: 12) != nil
    }()

    private static let images: [String: NSImage] = {
        Dictionary(uniqueKeysWithValues: ["codex", "more", "more-dots", "refresh", "reset"].map { name in
            guard let url = resourceBundle.url(forResource: name, withExtension: "svg"),
                  let image = NSImage(contentsOf: url) else {
                preconditionFailure("Missing design icon: \(name).svg")
            }
            image.isTemplate = false
            return (name, image)
        })
    }()

    static func font(_ size: CGFloat) -> Font {
        hasBundledFont ? .custom(fontName, fixedSize: size) : .system(size: size)
    }

    static func icon(_ name: String) -> Image {
        guard let image = images[name] else {
            preconditionFailure("Unknown design icon: \(name)")
        }
        return Image(nsImage: image)
    }
}
