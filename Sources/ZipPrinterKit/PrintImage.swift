import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an arbitrary image or PDF into the JPEG the printer expects.
public enum PrintImage {
    /// Pixel size of the JPEG sent to the printer. The ZIP prints 2x3" at
    /// 313x400 dpi (640x1224 non-square dots) and stretches whatever JPEG it
    /// receives onto that grid, so we send square pixels at exactly 2:3, 640
    /// wide to match the print head, in whole 16-pixel JPEG blocks.
    public static var size = CGSize(width: 640, height: 960)

    /// The printer decodes from a small receive buffer (roughly 48 KB), so
    /// files are kept under this size.
    public static var maxFileSize = 45_000

    public enum Layout: String, CaseIterable, Identifiable {
        case fill   // crop to cover the whole sheet
        case fit    // show the whole image, with white borders

        public var id: String { rawValue }
    }

    public struct Options: Equatable {
        public var layout: Layout = .fill
        /// Extra clockwise quarter-turns applied after auto-rotation.
        public var quarterTurns = 0
        /// Rotate landscape images so they use the whole portrait sheet.
        public var autoRotate = true
        /// Where to center a `.fill` crop, in -1...1 along the overflowing axis.
        public var focus = CGPoint.zero

        public init() {}
    }

    // MARK: Loading

    /// Loads an image file (anything ImageIO understands, EXIF orientation
    /// applied) or the first page of a PDF.
    public static func load(_ url: URL) -> CGImage? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return renderPDF(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Loads encoded image data, such as a PNG or JPEG.
    public static func load(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Reads a photo from the clipboard: an image or PDF file copied in
    /// Finder, or an image copied from an app. Returns the image and a name
    /// to show for it.
    public static func load(from pasteboard: NSPasteboard) -> (image: CGImage, name: String)? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let url = urls?.first {
            return load(url).map { ($0, url.lastPathComponent) }
        }
        let imageTypes = [UTType.png, .tiff, .jpeg, .heic].map { NSPasteboard.PasteboardType($0.identifier) }
        if let type = pasteboard.availableType(from: imageTypes),
           let data = pasteboard.data(forType: type), let image = load(data) {
            return (image, "Pasted image")
        }
        // Anything else AppKit can draw, such as a PDF selection.
        if let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation, let image = load(tiff) {
            return (image, "Pasted image")
        }
        return nil
    }

    private static let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]

    static func renderPDF(_ url: URL, longSide: CGFloat = 2400) -> CGImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        var box = page.getBoxRect(.cropBox)
        if page.rotationAngle % 180 != 0 { box.size = CGSize(width: box.height, height: box.width) }
        let scale = longSide / max(box.width, box.height)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Rendering

    /// Renders `image` onto a white canvas of `size`, rotated and cropped
    /// according to `options`.
    public static func render(_ image: CGImage, options: Options = Options(), size: CGSize = PrintImage.size) -> CGImage? {
        let landscape = image.width > image.height
        let turns = ((options.autoRotate && landscape ? 1 : 0) + options.quarterTurns) % 4
        let rotated = rotate(image, quarterTurns: turns) ?? image

        let width = Int(size.width), height = Int(size.height)
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        let source = CGSize(width: rotated.width, height: rotated.height)
        let scale = options.layout == .fill
            ? max(size.width / source.width, size.height / source.height)
            : min(size.width / source.width, size.height / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        let slackX = (size.width - drawn.width) / 2
        let slackY = (size.height - drawn.height) / 2
        // focus.y is top-down like the preview; CoreGraphics is bottom-up.
        let focus = options.layout == .fill ? options.focus : .zero
        let origin = CGPoint(x: slackX + slackX * clamp(focus.x),
                             y: slackY - slackY * clamp(focus.y))
        ctx.draw(rotated, in: CGRect(origin: origin, size: drawn))
        return ctx.makeImage()
    }

    /// Encodes at the highest quality that fits in `maxBytes`. If even low
    /// quality doesn't fit, it sends fewer pixels instead: the printer
    /// stretches any JPEG onto the sheet, so a smaller one still fills it.
    public static func jpegData(_ image: CGImage, maxBytes: Int = PrintImage.maxFileSize) -> Data? {
        var smallest: Data?
        // Steps of 64 keep 2:3 images in whole 16-pixel JPEG blocks.
        for width in stride(from: image.width, through: image.width / 2, by: -64) {
            guard let scaled = width == image.width ? image : resize(image, width: width) else { break }
            for quality in stride(from: 0.9, through: 0.3, by: -0.05) {
                guard let data = jpegData(scaled, quality: quality) else { return nil }
                if data.count <= maxBytes { return data }
                if data.count < smallest?.count ?? .max { smallest = data }
            }
        }
        return smallest
    }

    public static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)   // clockwise
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, width: Int) -> CGImage? {
        let height = image.height * width / image.width
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    private static func clamp(_ v: CGFloat) -> CGFloat { min(max(v, -1), 1) }
}
