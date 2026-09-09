import AppKit
import SwiftUI

/// Renders the popover in both appearances to PNG files (2× scale).
@MainActor
enum Snapshot {
    static func write(store: AppStore, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, scheme) in [("popover-dark", ColorScheme.dark), ("popover-light", ColorScheme.light)] {
            let view = PopoverView().environment(store).environment(\.colorScheme, scheme).environment(\.snapshotMode, true)
                .background(scheme == .dark ? Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1)) : Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appending(path: "\(name).png"))
                }
            }
        }
    }
}
