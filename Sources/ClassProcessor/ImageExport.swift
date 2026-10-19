import Foundation
import ImageIO
import UniformTypeIdentifiers
import libwebp

enum ImageExport {
    /// JPG for the printer: sRGB (embedded profile from the CGImage), 300 DPI.
    static func jpegData(_ image: CGImage, quality: Double = 0.95, dpi: Int = 300) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppError.encodeFailed("JPEG")
        }
        let jfif: [CFString: Any] = [
            kCGImagePropertyJFIFXDensity: dpi,
            kCGImagePropertyJFIFYDensity: dpi,
            kCGImagePropertyJFIFDensityUnit: 1,
        ]
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyJFIFDictionary: jfif,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AppError.encodeFailed("JPEG") }
        return data as Data
    }

    /// WebP via the bundled libwebp (macOS cannot write WebP by itself).
    static func webpData(_ image: CGImage, quality: Float) throws -> Data {
        let w = image.width
        let h = image.height
        let stride = w * 4
        var pixels = [UInt8](repeating: 0, count: stride * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw AppError.encodeFailed("WebP") }

        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buf in
            WebPEncodeRGBA(buf.baseAddress, Int32(w), Int32(h), Int32(stride), quality, &output)
        }
        guard size > 0, let output else { throw AppError.encodeFailed("WebP") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    static var webpVersion: String {
        let v = WebPGetEncoderVersion()
        return "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// Writes to a hidden temp file then renames, so hotfolder/sync never sees half a file.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? fm.removeItem(at: tmp)
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
    }
}
