import AppKit
import CoreImage
import CoreVideo
import SwiftUI
import XCTest
@testable import StupidMirrorApp

@MainActor
final class PreviewFrameRenderTests: XCTestCase {
    /// Stream previews reach SwiftUI as bitmaps. An NSCIImageRep would make
    /// every draw run Core Image and wait for a GPU readback on the main
    /// thread, which starved the MainActor tool router (screen_frame).
    func testPreviewImageIsBitmapBacked() throws {
        let pixelBuffer = try Self.pixelBuffer(width: 120, height: 260, hue: 0.3)
        let image = try XCTUnwrap(MirrorCaptureSession.previewImage(from: pixelBuffer))

        XCTAssertEqual(image.size, NSSize(width: 120, height: 260))
        XCTAssertFalse(image.representations.contains { $0 is NSCIImageRep })
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        XCTAssertEqual(cgImage.width, 120)
        XCTAssertEqual(cgImage.height, 260)
    }

    // MARK: Measurement

    @MainActor
    final class Feed: ObservableObject {
        @Published var frame: NSImage?
    }

    struct Panel: View {
        @ObservedObject var feed: Feed
        let bezel: MirrorBezel
        let session: MirrorCaptureSession

        var body: some View {
            DeviceBezelView(bezel: bezel, screenImage: feed.frame, mirrorSession: session) {
                ZStack {
                    Color.black
                    if let frame = feed.frame {
                        Image(nsImage: frame).resizable().scaledToFit()
                    }
                }
            }
            .padding(24)
            .frame(width: 1100, height: 700)
        }
    }

    /// Hosts the panel's bezel in a window, publishes simulator-sized frames
    /// the way a stream does and prints the main thread's CPU per frame.
    /// `legacy` uses the old CIImage-backed preview, `bitmap` the current one.
    ///
    ///   STUPIDMIRROR_RENDER_PROFILE=legacy|bitmap swift test --filter PreviewFrameRenderTests
    func testMainThreadCostPerPublishedFrame() async throws {
        guard let mode = ProcessInfo.processInfo.environment["STUPIDMIRROR_RENDER_PROFILE"] else {
            throw XCTSkip("Set STUPIDMIRROR_RENDER_PROFILE=legacy|bitmap to measure.")
        }
        let bezel = MirrorBezelCatalog.bezel(
            productType: "iPhone 17 Pro", name: "iPhone 17 Pro", platform: .iOS,
            formFactor: .standard, display: nil, aspectRatio: 1206.0 / 2622
        )
        let feed = Feed()
        let session = MirrorCaptureSession(simulatorUDID: "render-cost")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: Panel(feed: feed, bezel: bezel, session: session))
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // Prepared up front: only the main thread's drawing is measured.
        let buffers = try (0..<4).map { try Self.pixelBuffer(width: 1206, height: 2622, hue: Double($0) / 4) }
        let warmup = 8, measured = 32
        var cpu = 0.0
        for index in 0..<(warmup + measured) {
            // The app renders a bitmap preview off the main thread; build it
            // before the clock starts so only main-thread drawing is counted.
            let buffer = buffers[index % buffers.count]
            let image = mode == "legacy"
                ? Self.legacyPreviewImage(buffer)
                : try XCTUnwrap(MirrorCaptureSession.previewImage(from: buffer))
            let start = Self.threadCPUTime()
            feed.frame = image
            try await Task.sleep(for: .milliseconds(125))
            if index >= warmup { cpu += Self.threadCPUTime() - start }
        }
        print("render-cost mode=\(mode) main-thread CPU per frame \(String(format: "%.2f", cpu / Double(measured) * 1000)) ms")
    }

    /// The preview MirrorCaptureSession published before this fix.
    private static func legacyPreviewImage(_ pixelBuffer: CVPixelBuffer) -> NSImage {
        let representation = NSCIImageRep(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private static func pixelBuffer(width: Int, height: Int, hue: Double) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        let color = try XCTUnwrap(CIColor(color: NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1)))
        CIContext().render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
                           to: pixelBuffer)
        return pixelBuffer
    }

    private static func threadCPUTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
}
