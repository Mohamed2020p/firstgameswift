import Foundation
import UIKit
import CoreGraphics
import ImageIO

// MARK: - Image decoding for the GLB loader (ImageIO + CoreGraphics only).
// Every embedded image is decoded ONCE per file (down-scaled by ImageIO when larger than maxTextureSize) into an 8-bit RGBA bitmap; the
// per-role UIImages (base colour with baked tint, normal map, single channel roughness / metalness / occlusion) are derived from it and cached.

/// 8-bit RGBA bitmap that owns its memory through a CGContext (row 0 = top row of the image).
final class GLBPixelBuffer {
    let width: Int
    let height: Int
    let context: CGContext
    let bytesPerRow: Int
    let pixels: UnsafeMutablePointer<UInt8>
    /// true when at least one pixel has alpha < 255
    let hasTransparency: Bool

    init?(cgImage: CGImage) {
        let w: Int = cgImage.width
        let h: Int = cgImage.height
        if w <= 0 || h <= 0 { return nil }
        var sourceHasAlpha: Bool = true
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            sourceHasAlpha = false
        default:
            sourceHasAlpha = true
        }
        let alphaInfo: CGImageAlphaInfo = sourceHasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: alphaInfo.rawValue) else { return nil }
        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.setBlendMode(CGBlendMode.copy)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let p: UnsafeMutablePointer<UInt8> = raw.assumingMemoryBound(to: UInt8.self)
        let bpr: Int = ctx.bytesPerRow
        var transparent: Bool = false
        if sourceHasAlpha {
            var y: Int = 0
            while y < h && !transparent {
                var row: UnsafeMutablePointer<UInt8> = p + y * bpr + 3
                var x: Int = 0
                while x < w {
                    if row.pointee != 255 { transparent = true; break }
                    row += 4
                    x += 1
                }
                y += 1
            }
        }
        self.width = w
        self.height = h
        self.context = ctx
        self.bytesPerRow = bpr
        self.pixels = p
        self.hasTransparency = transparent
    }

    // sRGB transfer functions used to bake linear glTF colour factors into sRGB texels exactly
    static func srgbToLinear(_ c: Float) -> Float {
        if c <= 0.04045 { return c / 12.92 }
        return powf((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ c: Float) -> Float {
        let v: Float = min(max(c, 0), 1)
        if v <= 0.0031308 { return v * 12.92 }
        return 1.055 * powf(v, 1.0 / 2.4) - 0.055
    }

    static func tintTable(_ factor: Float) -> [UInt8] {
        var t: [UInt8] = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let lin: Float = GLBPixelBuffer.srgbToLinear(Float(i) / 255.0) * factor
            let enc: Float = GLBPixelBuffer.linearToSRGB(lin)
            t[i] = UInt8(min(max(enc * 255.0 + 0.5, 0), 255))
        }
        return t
    }

    /// Colour image. `tint` is a LINEAR multiplier (glTF baseColorFactor) baked into the texels; `dropAlpha` forces an opaque bitmap.
    func makeColorImage(tint: (Float, Float, Float), dropAlpha: Bool) -> UIImage? {
        let tinted: Bool = abs(tint.0 - 1) > 0.004 || abs(tint.1 - 1) > 0.004 || abs(tint.2 - 1) > 0.004
        let needsCopy: Bool = tinted || (dropAlpha && hasTransparency)
        if !needsCopy {
            guard let cg = context.makeImage() else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
        let keepAlpha: Bool = hasTransparency && !dropAlpha
        let alphaInfo: CGImageAlphaInfo = keepAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: alphaInfo.rawValue) else { return nil }
        guard let outRaw = out.data else { return nil }
        let dst: UnsafeMutablePointer<UInt8> = outRaw.assumingMemoryBound(to: UInt8.self)
        let dbpr: Int = out.bytesPerRow
        let lutR: [UInt8] = GLBPixelBuffer.tintTable(tint.0)
        let lutG: [UInt8] = GLBPixelBuffer.tintTable(tint.1)
        let lutB: [UInt8] = GLBPixelBuffer.tintTable(tint.2)
        for y in 0..<height {
            var sp: UnsafeMutablePointer<UInt8> = pixels + y * bytesPerRow
            var dp: UnsafeMutablePointer<UInt8> = dst + y * dbpr
            for _ in 0..<width {
                dp[0] = lutR[Int(sp[0])]
                dp[1] = lutG[Int(sp[1])]
                dp[2] = lutB[Int(sp[2])]
                dp[3] = keepAlpha ? sp[3] : 255
                sp += 4
                dp += 4
            }
        }
        guard let cg = out.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Single channel (0 = R, 1 = G, 2 = B) 8-bit greyscale image, values multiplied by `scale` (clamped).
    func makeGrayImage(channel: Int, scale: Float) -> UIImage? {
        let space: CGColorSpace = CGColorSpaceCreateDeviceGray()
        guard let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        guard let outRaw = out.data else { return nil }
        let dst: UnsafeMutablePointer<UInt8> = outRaw.assumingMemoryBound(to: UInt8.self)
        let dbpr: Int = out.bytesPerRow
        var lut: [UInt8] = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            lut[i] = UInt8(min(max(Float(i) * scale + 0.5, 0), 255))
        }
        let ch: Int = min(max(channel, 0), 2)
        for y in 0..<height {
            var sp: UnsafeMutablePointer<UInt8> = pixels + y * bytesPerRow + ch
            var dp: UnsafeMutablePointer<UInt8> = dst + y * dbpr
            for _ in 0..<width {
                dp.pointee = lut[Int(sp.pointee)]
                sp += 4
                dp += 1
            }
        }
        guard let cg = out.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

enum GLBImageDecoder {
    /// Decodes PNG/JPEG bytes. Images larger than `maxSize` (either side) are down-scaled by ImageIO while decoding (cheap).
    static func decode(data: Data, maxSize: Int) -> GLBPixelBuffer? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions as CFDictionary) else { return nil }
        var pixelW: Int = 0
        var pixelH: Int = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int { pixelW = w }
            if let h = props[kCGImagePropertyPixelHeight] as? Int { pixelH = h }
        }
        var image: CGImage? = nil
        if maxSize > 0 && max(pixelW, pixelH) > maxSize {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        }
        if image == nil {
            let fullOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateImageAtIndex(source, 0, fullOptions as CFDictionary)
        }
        guard let cg = image else { return nil }
        return GLBPixelBuffer(cgImage: cg)
    }
}

/// Decodes each embedded image once and hands out the per-role UIImages (cached by index + role + tint).
final class GLBImageStore {
    private let binary: GLBBinaryStore
    private let maxSize: Int
    private var lastIndex: Int = -1
    private var lastBuffer: GLBPixelBuffer? = nil
    private var failed: Set<Int> = []
    private var cache: [String: UIImage] = [:]
    private(set) var decodedCount: Int = 0
    private(set) var failedCount: Int = 0

    init(binary: GLBBinaryStore, maxSize: Int) {
        self.binary = binary
        self.maxSize = maxSize
    }

    private func imageBytes(_ index: Int) -> Data? {
        let images: [GLBSchema.Image] = binary.root.images ?? []
        if index < 0 || index >= images.count { return nil }
        let im: GLBSchema.Image = images[index]
        if let view = im.bufferView {
            return try? binary.bufferViewData(view)
        }
        return binary.imageURIData(im)
    }

    /// One-entry scratch cache: consecutive requests for the same image (e.g. an ORM texture used for roughness, metalness and occlusion) decode once.
    private func buffer(_ index: Int) -> GLBPixelBuffer? {
        if index == lastIndex, let b = lastBuffer { return b }
        if failed.contains(index) { return nil }
        guard let bytes = imageBytes(index), let decoded = GLBImageDecoder.decode(data: bytes, maxSize: maxSize) else {
            failed.insert(index)
            failedCount += 1
            return nil
        }
        decodedCount += 1
        lastIndex = index
        lastBuffer = decoded
        return decoded
    }

    func releaseScratch() {
        lastIndex = -1
        lastBuffer = nil
    }

    func colorImage(image index: Int, tint: (Float, Float, Float), dropAlpha: Bool) -> UIImage? {
        let key: String = String(format: "c%d_%.3f_%.3f_%.3f_%d", index, tint.0, tint.1, tint.2, dropAlpha ? 1 : 0)
        if let hit = cache[key] { return hit }
        guard let b = buffer(index), let img = b.makeColorImage(tint: tint, dropAlpha: dropAlpha) else { return nil }
        cache[key] = img
        return img
    }

    func grayImage(image index: Int, channel: Int, scale: Float) -> UIImage? {
        let key: String = String(format: "g%d_%d_%.3f", index, channel, scale)
        if let hit = cache[key] { return hit }
        guard let b = buffer(index), let img = b.makeGrayImage(channel: channel, scale: scale) else { return nil }
        cache[key] = img
        return img
    }

    /// true when the image has real (non 255) alpha values
    func hasTransparency(image index: Int) -> Bool {
        guard let b = buffer(index) else { return false }
        return b.hasTransparency
    }
}
