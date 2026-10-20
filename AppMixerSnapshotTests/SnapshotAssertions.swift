import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Light or dark, independent of the machine's setting.
enum SnapshotAppearance: String, CaseIterable, Sendable {
    case light
    case dark

    var nsAppearance: NSAppearance {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)!
    }
}

/// How far a render may drift from its reference before the test fails.
///
/// A pixel only counts as different when one of its channels moves by more than `channelTolerance` (out of 255).
/// Rendering the same view on Apple silicon and Intel differs in thousands of pixels, but by at most 3–4 per
/// channel (blending and anti-aliasing rounding), while a real change to text, color, or layout moves pixels by
/// tens to hundreds. The test fails once more than `maxDifferentPixels` pixels differ: a single changed
/// character at 2x is well over that.
struct SnapshotTolerance: Sendable {
    var channelTolerance: Int = 8
    var maxDifferentPixels: Int = 20

    static let `default` = SnapshotTolerance()
}

/// Compares `view` to `__Snapshots__/<environment>/<name>-<appearance>.png` next to the calling test file.
///
/// - References are kept per `SnapshotEnvironment`, because text layout differs between Xcode versions.
/// - Missing references are recorded and the test fails, so CI can never pass without them.
/// - Set `RECORD_SNAPSHOTS=1` (`make record-snapshots`) to overwrite every reference instead of comparing.
/// - On a mismatch, the actual render, the reference, and a diff are written to
///   `SNAPSHOT_ARTIFACTS/<environment>` (default `build/snapshot-failures`) and attached to the test.
@MainActor
func assertSnapshot(
    of view: some View,
    named name: String,
    appearance: SnapshotAppearance,
    tolerance: SnapshotTolerance = .default,
    filePath: StaticString = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let fileName = "\(name)-\(appearance.rawValue)"
    let environment = SnapshotEnvironment.current
    let testFile = URL(fileURLWithPath: "\(filePath)")
    let referenceURL = testFile.deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
        .appendingPathComponent(environment)
        .appendingPathComponent("\(fileName).png")
    let artifacts = SnapshotFiles.artifactsDirectory(testFile: testFile).appendingPathComponent(environment)

    let actual = SnapshotRenderer.render(view, appearance: appearance)
    SnapshotFiles.removeArtifacts(named: fileName, in: artifacts)

    if SnapshotFiles.isRecording {
        SnapshotFiles.write(actual, to: referenceURL)
        return
    }

    guard let reference = SnapshotFiles.read(referenceURL) else {
        SnapshotFiles.write(actual, to: referenceURL)
        SnapshotFiles.write(actual, to: artifacts.appendingPathComponent("\(fileName).actual.png"))
        Issue.record(
            """
            No \(environment) reference for \(fileName); recorded \(referenceURL.path).
              Review and commit it. From CI, adopt the run's renders with `make adopt-ci-snapshots RUN=<run id>`.
            """,
            sourceLocation: sourceLocation
        )
        return
    }

    let diff = PixelDiff(reference: reference, actual: actual, channelTolerance: tolerance.channelTolerance)
    guard diff.differentPixels > tolerance.maxDifferentPixels else { return }

    let actualURL = artifacts.appendingPathComponent("\(fileName).actual.png")
    let diffURL = artifacts.appendingPathComponent("\(fileName).diff.png")
    let referenceCopyURL = artifacts.appendingPathComponent("\(fileName).reference.png")
    SnapshotFiles.write(actual.image, to: actualURL)
    SnapshotFiles.write(reference.image, to: referenceCopyURL)
    if let diffImage = diff.image { SnapshotFiles.write(diffImage, to: diffURL) }
    for url in [actualURL, diffURL] {
        if let data = try? Data(contentsOf: url) {
            Attachment.record(data, named: url.lastPathComponent, sourceLocation: sourceLocation)
        }
    }

    Issue.record(
        """
        Snapshot \(fileName) doesn't match its \(environment) reference: \(diff.summary)
          reference: \(referenceURL.path)
          actual:    \(actualURL.path)
          diff:      \(diffURL.path)
          If the change is intended, run `make record-snapshots` (or, from CI, `make adopt-ci-snapshots RUN=<run id>`) and commit the PNGs.
        """,
        sourceLocation: sourceLocation
    )
}

/// The toolchain a render belongs to, e.g. `macos26-xcode27`. The SDK the tests are built with changes text
/// layout (Xcode 26 lays the popover out a few points shorter than Xcode 27), so each macOS + Xcode major
/// version has its own references.
enum SnapshotEnvironment {
    static let current: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let xcode = (Bundle(for: BundleToken.self).object(forInfoDictionaryKey: "DTXcode") as? String)
            .flatMap { Int($0) }
            .map { String($0 / 100) } ?? "unknown"
        return "macos\(os)-xcode\(xcode)"
    }()

    private final class BundleToken {}
}

// MARK: - Rendering

/// A window that always reports a 2x backing scale and key status, so renders don't depend on the machine's
/// display (CI runners have 1x virtual screens) or on whether the test process is the active app.
private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { SnapshotRenderer.scale }
}

@MainActor
enum SnapshotRenderer {
    nonisolated static let scale: CGFloat = 2

    /// Lays the view out at its ideal size and draws it offscreen at 2x on an opaque window background
    /// (the real panel's material would show whatever is behind it, which isn't reproducible).
    static func render(_ view: some View, appearance: SnapshotAppearance) -> PixelImage {
        _ = NSApplication.shared

        let content = view
            .background(Color(nsColor: .windowBackgroundColor))
            // Pin the accent (the default blue) so a user's System Settings accent color doesn't leak into renders.
            .tint(.blue)
        let host = NSHostingView(rootView: content)
        host.appearance = appearance.nsAppearance

        let window = SnapshotWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = appearance.nsAppearance
        window.contentView = host

        let fitting = host.fittingSize
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI commit any updates scheduled during the first layout.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return PixelImage(rep.cgImage!)
    }
}

// MARK: - Pixels

/// An image normalized to 8-bit premultiplied RGBA in sRGB, so references and renders compare byte for byte.
struct PixelImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    var image: CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

struct PixelDiff {
    let sizeMismatch: (reference: (Int, Int), actual: (Int, Int))?
    let differentPixels: Int
    let maxChannelDelta: Int
    /// Bounding box of the differing pixels, in points (top-left origin).
    let region: CGRect?
    /// The reference, dimmed, with differing pixels in magenta.
    let image: CGImage?

    init(reference: PixelImage, actual: PixelImage, channelTolerance: Int) {
        guard reference.width == actual.width, reference.height == actual.height else {
            sizeMismatch = ((reference.width, reference.height), (actual.width, actual.height))
            differentPixels = .max
            maxChannelDelta = 255
            region = nil
            image = nil
            return
        }
        sizeMismatch = nil

        var count = 0
        var maxDelta = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var output = [UInt8](repeating: 0, count: reference.bytes.count)
        for pixel in 0..<(reference.width * reference.height) {
            let offset = pixel * 4
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(reference.bytes[offset + channel]) - Int(actual.bytes[offset + channel])))
            }
            maxDelta = max(maxDelta, delta)
            if delta > channelTolerance {
                count += 1
                let x = pixel % reference.width, y = pixel / reference.width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                output[offset] = 255
                output[offset + 1] = 0
                output[offset + 2] = 255
                output[offset + 3] = 255
            } else {
                // Dim the unchanged reference so the magenta pixels stand out.
                for channel in 0..<3 {
                    output[offset + channel] = UInt8(Int(reference.bytes[offset + channel]) / 4 + 96)
                }
                output[offset + 3] = 255
            }
        }

        differentPixels = count
        maxChannelDelta = maxDelta
        let scale = SnapshotRenderer.scale
        region = count == 0 ? nil : CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
        image = PixelImage(width: reference.width, height: reference.height, bytes: output).image
    }

    var summary: String {
        if let sizeMismatch {
            return "size changed from \(sizeMismatch.reference.0)x\(sizeMismatch.reference.1) px to \(sizeMismatch.actual.0)x\(sizeMismatch.actual.1) px"
        }
        let region = region.map { "x \(Int($0.minX))–\(Int($0.maxX.rounded(.up))), y \(Int($0.minY))–\(Int($0.maxY.rounded(.up))) pt" } ?? "none"
        return "\(differentPixels) pixels differ (max channel delta \(maxChannelDelta)) in region \(region)"
    }
}

// MARK: - Files

enum SnapshotFiles {
    static var isRecording: Bool {
        let value = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] ?? ""
        return !value.isEmpty && value != "0"
    }

    static func artifactsDirectory(testFile: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let repository = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return repository.appendingPathComponent("build/snapshot-failures")
    }

    static func read(_ url: URL) -> PixelImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return PixelImage(image)
    }

    static func write(_ image: PixelImage, to url: URL) {
        write(image.image, to: url)
    }

    /// Writes a PNG tagged at 144 dpi, so it opens at its real point size.
    static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            Issue.record("Couldn't write \(url.path)")
            return
        }
        let dpi = 72 * SnapshotRenderer.scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        if !CGImageDestinationFinalize(destination) {
            Issue.record("Couldn't write \(url.path)")
        }
    }

    static func removeArtifacts(named name: String, in directory: URL) {
        for suffix in ["actual", "diff", "reference"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).\(suffix).png"))
        }
    }
}
