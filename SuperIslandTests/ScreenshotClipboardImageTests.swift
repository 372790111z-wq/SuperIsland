import AppKit
import ImageIO
import XCTest
@testable import SuperIsland

final class ScreenshotClipboardImageTests: XCTestCase {
    private func image(_ type: NSBitmapImageRep.FileType = .png) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(rep.bitmapData!, 123, rep.bytesPerRow * rep.pixelsHigh)
        return rep.representation(using: type, properties: [:])!
    }
    private func entry(_ type: NSPasteboard.PasteboardType = .png, data: Data? = nil) -> NSPasteboardItem {
        let e = NSPasteboardItem(); e.setData(data ?? image(), forType: type); return e
    }
    func testMixedImageRepresentationsNeedNoAppNameOrVersion() throws {
        for extra in [NSPasteboard.PasteboardType.string, .fileURL, .URL, .init("example.vendor.metadata"), ScreenshotClipboardImage.transient] {
            let e = entry(); e.setString("unused", forType: extra)
            let png = try XCTUnwrap(ScreenshotClipboardImage.png(from: [e]))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(rep.pixelsWide, 3); XCTAssertEqual(rep.pixelsHigh, 2)
        }
        let e = entry()
        e.setString("file:///not/read/image.png", forType: .fileURL)
        e.setString("", forType: ScreenshotClipboardImage.transient)
        e.setData(Data([1, 2, 3]), forType: .init("any.vendor.metadata"))
        XCTAssertNotNil(ScreenshotClipboardImage.png(from: [e]))
    }
    func testPureTextOrURLNeverBecomesAnImage() {
        for type in [NSPasteboard.PasteboardType.string, .fileURL, .URL] {
            let e = NSPasteboardItem(); e.setString("https://example.invalid/image.png", forType: type)
            XCTAssertNil(ScreenshotClipboardImage.png(from: [e]))
        }
    }
    func testConcealedAndAutomaticImagesAreRejectedEvenWithOtherMetadata() {
        for marker in [ScreenshotClipboardImage.concealed, ScreenshotClipboardImage.automatic] {
            let e = entry(); e.setString("", forType: marker)
            e.setString("", forType: ScreenshotClipboardImage.transient)
            XCTAssertNil(ScreenshotClipboardImage.png(from: [e]))
        }
    }
    func testBrokenPreferredRepresentationFallsBackToValidTiffOrJpeg() {
        let e = entry(data: Data([0, 1, 2])); e.setData(image(.tiff), forType: .tiff)
        XCTAssertNotNil(ScreenshotClipboardImage.png(from: [e]))
        XCTAssertNotNil(ScreenshotClipboardImage.png(from: [entry(.init("public.jpeg"), data: image(.jpeg))]))
        XCTAssertNil(ScreenshotClipboardImage.png(from: [entry(data: Data([0, 1]))]))
    }
    func testSingleItemAndEncodedByteLimits() {
        XCTAssertNil(ScreenshotClipboardImage.png(from: []))
        XCTAssertNil(ScreenshotClipboardImage.png(from: [entry(), entry()]))
        XCTAssertNil(ScreenshotClipboardImage.png(from: [entry()], maximumBytes: 8))
    }
    func testDimensionsRejectExpansionBombsWithoutDecoding() {
        XCTAssertTrue(ScreenshotClipboardImage.permittedDimensions(width: 7680, height: 4320))
        for (w, h) in [(0, 10), (10, -1), (Int.max, 2), (2, Int.max), (20000, 20000), (32769, 1)] {
            XCTAssertFalse(ScreenshotClipboardImage.permittedDimensions(width: w, height: h))
        }
    }
    func testOrientationIsAppliedWithoutShrinkingOriginal() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image()))
        CGImageDestinationAddImage(destination, try XCTUnwrap(rep.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let png = try XCTUnwrap(ScreenshotClipboardImage.png(from: [entry(.init("public.jpeg"), data: data as Data)]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 2); XCTAssertEqual(decoded.pixelsHigh, 3)
    }
    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        var requested: [NSPasteboard.PasteboardType] = []
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requested.append(type)
            item.setData(Data([0]), forType: type)
        }
    }
    func testAttachedTextURLsAndMetadataAreNeverRequested() {
        let provider = Provider(), e = entry()
        e.setDataProvider(provider, forTypes: [.string, .fileURL, .URL, .init("private.metadata")])
        XCTAssertNotNil(ScreenshotClipboardImage.png(from: [e]))
        XCTAssertTrue(provider.requested.isEmpty)
        let secret = NSPasteboardItem()
        secret.setDataProvider(provider, forTypes: [.png])
        secret.setString("", forType: ScreenshotClipboardImage.concealed)
        XCTAssertNil(ScreenshotClipboardImage.png(from: [secret]))
        XCTAssertTrue(provider.requested.isEmpty, "Concealed image data must never be requested")
    }
    func testHEICCapabilityAndMultiFrameRejection() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image()))
        let cgImage = try XCTUnwrap(rep.cgImage)
        let heic = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(heic, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        XCTAssertNotNil(ScreenshotClipboardImage.png(from: [entry(.init("public.heic"), data: heic as Data)]))
        let tiff = NSMutableData()
        let multi = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(multi, cgImage, nil); CGImageDestinationAddImage(multi, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(multi))
        XCTAssertNil(ScreenshotClipboardImage.png(from: [entry(.tiff, data: tiff as Data)]))
    }
    func testExistingGenerationAndRestartsNeverImportHistory() {
        var sampler = ScreenshotClipboardSampler(changeCount: 10)
        XCTAssertFalse(sampler.shouldRead(changeCount: 10, transient: false))
        XCTAssertTrue(sampler.shouldRead(changeCount: 11, transient: false))
        XCTAssertFalse(sampler.shouldRead(changeCount: 11, transient: false))
        sampler = .init(changeCount: 12)
        XCTAssertFalse(sampler.shouldRead(changeCount: 12, transient: true))
    }
    func testTransientNeedsStableSecondPollAndReplacementCancelsIt() {
        var sampler = ScreenshotClipboardSampler(changeCount: 0)
        XCTAssertFalse(sampler.shouldRead(changeCount: 1, transient: true))
        XCTAssertFalse(sampler.shouldRead(changeCount: 2, transient: true))
        XCTAssertTrue(sampler.shouldRead(changeCount: 2, transient: true))
        XCTAssertFalse(sampler.shouldRead(changeCount: 2, transient: true))
        XCTAssertFalse(sampler.shouldRead(changeCount: 3, transient: true))
        XCTAssertTrue(sampler.shouldRead(changeCount: 4, transient: false))
    }
}
