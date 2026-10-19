import Foundation
import CoreGraphics
import ImageIO

/// Image loading, photo placement and the final 1800×1200 render.
enum Imaging {
    static let canvas = CGSize(width: 1800, height: 1200)   // 4R master
    static let previewMaxPixels = 2000

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Loading

    /// Whole image (WebP / PNG), as is.
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Fast snapshot for the preview: embedded/decoded thumbnail, EXIF rotation applied.
    static func preview(_ url: URL, maxPixels: Int = previewMaxPixels) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Pixel size of the camera file after EXIF rotation.
    static func orientedSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Full resolution, EXIF rotation applied (used for PROCESS and the phone WebP).
    static func full(_ url: URL) -> CGImage? {
        guard let size = orientedSize(url) else { return nil }
        return preview(url, maxPixels: Int(max(size.width, size.height)))
    }

    /// Bounding box of the transparent part of a master (top-left pixels).
    static func transparentArea(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = alpha.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] < 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        // Scale to the 1800×1200 canvas in case the master has another size.
        let sx = canvas.width / CGFloat(w), sy = canvas.height / CGFloat(h)
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    // MARK: - Placement

    /// Where the photo is drawn on the canvas (top-left coordinates).
    /// `zoom` 1 = fill the area; `offset` = photo centre minus area centre, clamped so the area stays covered.
    static func photoRect(photo: CGSize, area: CGRect, zoom: Double, offset: CGPoint) -> CGRect {
        let base = max(area.width / photo.width, area.height / photo.height)
        let scale = base * CGFloat(max(1, zoom))
        let size = CGSize(width: photo.width * scale, height: photo.height * scale)
        let o = clamp(offset: offset, drawn: size, area: area)
        return CGRect(x: area.midX + o.x - size.width / 2, y: area.midY + o.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func clamp(offset: CGPoint, drawn: CGSize, area: CGRect) -> CGPoint {
        let mx = max(0, (drawn.width - area.width) / 2)
        let my = max(0, (drawn.height - area.height) / 2)
        return CGPoint(x: min(mx, max(-mx, offset.x)), y: min(my, max(-my, offset.y)))
    }

    /// Text PNG fitted (aspect kept) and centred in the text area.
    static func textRect(text: CGSize, area: CGRect) -> CGRect {
        let s = min(area.width / text.width, area.height / text.height)
        let w = text.width * s, h = text.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    // MARK: - Render

    /// photo (under) + master + class name text → 1800×1200 sRGB.
    static func render(photo: CGImage, master: CGImage, text: CGImage?, area: CGRect, textArea: CGRect,
                       zoom: Double, offset: CGPoint) throws -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError.renderFailed
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Core Graphics is bottom-left based.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: canvas.height - r.maxY, width: r.width, height: r.height) }

        let pr = photoRect(photo: CGSize(width: photo.width, height: photo.height), area: area, zoom: zoom, offset: offset)
        ctx.saveGState()
        ctx.clip(to: flip(area))
        ctx.draw(photo, in: flip(pr))
        ctx.restoreGState()

        ctx.draw(master, in: CGRect(x: 0, y: 0, width: w, height: h))

        if let text {
            let tr = textRect(text: CGSize(width: text.width, height: text.height), area: textArea)
            ctx.draw(text, in: flip(tr))
        }
        guard let out = ctx.makeImage() else { throw AppError.renderFailed }
        return out
    }
}
