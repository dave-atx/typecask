import CoreText
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Writes Typecask/AppleFonts.json and the preview images for Apple's downloadable fonts.
///
/// Not a test: it runs in the UI test runner because that is an iOS process, so it sees exactly the
/// fonts iOS has built in and offers under Settings › General › Fonts › More Fonts, which differ from
/// the Mac's. The app previews downloadable fonts from these images instead of downloading each one as
/// it scrolls past. Run it on a freshly erased simulator, so fonts installed there don't read as built in:
///
///     TEST_RUNNER_TYPECASK_APPLE_FONTS_OUTPUT="$PWD/Typecask" xcodebuild test ... \
///         -only-testing:TypecaskUITests/ApplePreviewRenderer
final class ApplePreviewRenderer: XCTestCase {
    private struct Family: Encodable {
        let name: String
        let faces: Int
        let previewFace: String
        let style: String
        let builtIn: Bool
        /// The family's own script, as an ISO 15924 code: Latn for a Latin font, nil for a symbol font.
        let script: String?
        /// Every script the family covers, for filtering by.
        let scripts: [String]
        /// A line in the family's own script, then the sample text where it has Latin letters too; nil
        /// for a Latin font.
        let sample: String?
        /// Base name of the preview images; downloadable families only.
        var preview: String?
        /// Where the simulator keeps the downloaded preview face, on the Mac's disk, for
        /// build-catalog.py --apple-previews to subset. It drops this before the JSON is committed.
        var fontFile: String?
    }

    func testRenderApplePreviews() async throws {
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["TYPECASK_APPLE_FONTS_OUTPUT"],
                                   "set TEST_RUNNER_TYPECASK_APPLE_FONTS_OUTPUT to the Typecask folder")
        let root = URL(fileURLWithPath: output)
        let images = root.appending(path: "ApplePreviews")
        try? FileManager.default.removeItem(at: images)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        let downloadable = Self.families(matching: [kCTFontDownloadableAttribute: true])
        let builtIn = Self.families(matching: [:]).filter { name, faces in
            downloadable[name] == nil && faces.allSatisfy(Self.isSystemFont)
        }
        print("ApplePreviewRenderer: \(builtIn.count) built in, \(downloadable.count) downloadable")

        var families: [Family] = []
        for (name, faces) in builtIn {
            families.append(Self.describe(name, faces: faces.count, face: Self.previewFace(faces), builtIn: true))
        }
        // Names only cross into the tasks; Core Text's descriptors aren't Sendable.
        let jobs = downloadable.map { (name: $0.key, faces: $0.value.count, face: Self.previewFace($0.value)) }
            .sorted { $0.name < $1.name }
        // A few at a time: several are CJK families of tens of MB.
        try await withThrowingTaskGroup(of: Family?.self) { group in
            var pending = jobs.makeIterator()
            func next() {
                guard let (name, faces, face) = pending.next() else { return }
                group.addTask {
                    guard await Self.download(face) else {
                        print("ApplePreviewRenderer: \(name) didn't download")
                        return nil
                    }
                    var family = Self.describe(name, faces: faces, face: face, builtIn: false)
                    family.preview = try Self.renderPreviews(of: family, into: images)
                    let font = CTFontCreateWithName(face as CFString, 0, nil)
                    family.fontFile = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path()
                    return family
                }
            }
            for _ in 0..<6 { next() }
            while let family = try await group.next() {
                if let family { families.append(family) }
                next()
            }
        }

        families.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(families).write(to: root.appending(path: "AppleFonts.json"))
        print("ApplePreviewRenderer: wrote \(families.count) families")
    }

    // MARK: - Listing

    /// Faces by family, leaving out the hidden system families whose names start with a dot.
    private static func families(matching attributes: [CFString: Any]) -> [String: [CTFontDescriptor]] {
        let query = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let descriptors = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor] ?? []
        return Dictionary(grouping: descriptors) { descriptor in
            CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? ""
        }
        .filter { !$0.key.isEmpty && !$0.key.hasPrefix(".") }
    }

    private static func isSystemFont(_ descriptor: CTFontDescriptor) -> Bool {
        let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        return url?.path().contains("/System/Library/Fonts/") ?? false
    }

    private static func previewFace(_ faces: [CTFontDescriptor]) -> String {
        let named = faces.map { descriptor in
            (name: CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? "",
             style: CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "")
        }
        return (named.first { $0.style == "Regular" } ?? named.min { $0.name.count < $1.name.count })!.name
    }

    private static func describe(_ name: String, faces: Int, face: String, builtIn: Bool) -> Family {
        let font = CTFontCreateWithName(face as CFString, 20, nil)
        let scripts = OwnScript(font, family: name, latinSample: sampleText)
        return Family(name: name, faces: faces, previewFace: face, style: classify(font), builtIn: builtIn,
                      script: scripts.script, scripts: scripts.scripts, sample: scripts.sample,
                      preview: nil, fontFile: nil)
    }

    private static func download(_ postScriptName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let descriptors = [CTFontDescriptorCreateWithAttributes(
                [kCTFontNameAttribute: postScriptName] as CFDictionary)] as CFArray
            // didFinish arrives exactly once, after any errors.
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors, nil) { state, _ in
                if state == .didFinish {
                    let font = CTFontCreateWithName(postScriptName as CFString, 0, nil)
                    continuation.resume(returning: CTFontCopyPostScriptName(font) as String == postScriptName)
                }
                return true
            }
            if !started {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Classifying

    /// The same rules as classify() in scripts/build-catalog.py, from the same tables, so Apple's fonts
    /// land in the same collections as the casks. Apple's older fonts often have no OS/2 table, so Core
    /// Text's symbolic traits, which it derives from whatever the font has, are the fallback.
    private static func classify(_ font: CTFont) -> String {
        let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?
        let post = CTFontCopyTable(font, CTFontTableTag(kCTFontTablePost), []) as Data?
        func byte(_ data: Data?, _ offset: Int) -> Int {
            guard let data, data.count > offset else { return 0 }
            return Int(data[data.startIndex + offset])
        }
        let familyClass = byte(os2, 30)
        let familyType = byte(os2, 32)
        let serifStyle = byte(os2, 33)
        let proportion = byte(os2, 35)
        let fixedPitch = (12..<16).contains { byte(post, $0) != 0 }
        let traits = CTFontGetSymbolicTraits(font)
        let traitClass = Int(traits.rawValue >> 28)

        if fixedPitch || proportion == 9 || traits.contains(.traitMonoSpace) {
            return "monospaced"
        }
        if familyType == 3 || familyClass == 10 || (os2 == nil && traitClass == 10) {
            return "handwriting"
        }
        if familyType == 4 || familyType == 5 || familyClass == 9 || familyClass == 12
            || (os2 == nil && (traitClass == 9 || traitClass == 12)) {
            return "display"
        }
        if familyType == 2 && serifStyle != 0 {
            return (11...15).contains(serifStyle) ? "sansSerif" : "serif"
        }
        if (1...7).contains(familyClass) || (familyClass == 0 && (1...7).contains(traitClass)) {
            return "serif"
        }
        return "sansSerif"
    }

    // MARK: - Rendering

    /// Two images per family, each sized for where the app shows it: three lines at 20pt for a grid
    /// card, and two lines at 64pt for the sample list and the detail page.
    private static func renderPreviews(of family: Family, into directory: URL) throws -> String {
        let base = "ApplePreview-" + family.name.replacing(/[^A-Za-z0-9]+/, with: "-")
        let text = family.sample ?? sampleText
        for (suffix, size, width, lines, scale) in [("card", 20.0, 190.0, 3, 3), ("row", 64.0, 1000.0, 2, 2)] {
            let font = CTFontCreateWithName(family.previewFace as CFString, size, nil)
            let image = render(text, font: font, width: width, lines: lines, scale: CGFloat(scale))
            let url = directory.appending(path: "\(base)-\(suffix)@\(scale)x.png")
            guard let image, let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
        return base
    }

    /// Black text on clear, wrapped to `width` and cut off after `lines` with an ellipsis, written as
    /// grey and alpha: the app draws it as a template, so only the alpha matters, and two channels
    /// compress to about half the size of RGBA.
    private static func render(_ text: String, font: CTFont, width: CGFloat, lines: Int, scale: CGFloat) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: font as UIFont, .foregroundColor: UIColor.black, .paragraphStyle: paragraph
        ])
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let bounds = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let size = CGSize(width: ceil(min(bounds.width, width)),
                          height: ceil(min(bounds.height, lineHeight * CGFloat(lines) + 1)))
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rgba = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            string.draw(with: CGRect(origin: .zero, size: size),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
        guard let source = rgba.cgImage else { return nil }

        let (pixelWidth, pixelHeight) = (source.width, source.height)
        var alpha = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
        alpha.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                                    bitsPerComponent: 8, bytesPerRow: pixelWidth, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            context?.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        var greyAlpha = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 2)
        for index in alpha.indices {
            greyAlpha[index * 2 + 1] = alpha[index]
        }
        guard let provider = CGDataProvider(data: Data(greyAlpha) as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 16,
                       bytesPerRow: pixelWidth * 2, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// SAMPLE_TEXT in scripts/build-catalog.py, which the catalog gives the app as its sample text.
    private static let sampleText = "The quick brown fox jumps over the lazy dog 0123456789 {}[]()<>=!&|"
}
