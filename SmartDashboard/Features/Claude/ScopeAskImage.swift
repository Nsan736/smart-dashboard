import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「撮って聞く」で送る画像の処理。座標はどれも画像のピクセル(左上が原点)。
enum ScopeAskImage {
    /// 囲みの外側を暗くする濃さ(黒の不透明度)
    static let outsideDarkness: CGFloat = 0.8
    /// これより小さい囲みは、囲みとして扱わない(画像全体を送る)
    static let minimumShapeSide: CGFloat = 24
    static let jpegQuality = 0.8

    /// 画面いっぱい(aspectFill)に表示していた映像のうち、画面に見えていた範囲
    static func visibleRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = min(imageSize.width, viewSize.width / scale)
        let height = min(imageSize.height, viewSize.height / scale)
        return CGRect(x: ((imageSize.width - width) / 2).rounded(), y: ((imageSize.height - height) / 2).rounded(),
                      width: width.rounded(), height: height.rounded())
    }

    /// 指で描いた形を囲む四角(画像の中に収める)。点が少ない、または小さすぎるときは nil(画像全体を使う)。
    static func bounds(of shape: [CGPoint], imageSize: CGSize) -> CGRect? {
        guard shape.count >= 3 else { return nil }
        let xs = shape.map(\.x)
        let ys = shape.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(origin: .zero, size: imageSize))
            .integral
        guard !rect.isNull, rect.width >= minimumShapeSide, rect.height >= minimumShapeSide else { return nil }
        return rect
    }

    /// 長い辺を maxEdge 以下に縮めた大きさ(小さい画像は、そのまま)
    static func fittedSize(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxEdge, longest > 0 else { return (width, height) }
        let scale = Double(maxEdge) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// 切り出し・囲みの外側を暗くする・縮小を1回の描画で行う。shape がなければ画像全体。
    static func render(_ image: CGImage, shape: [CGPoint]?, maxEdge: Int) -> CGImage? {
        let full = CGSize(width: image.width, height: image.height)
        let crop = shape.flatMap { bounds(of: $0, imageSize: full) } ?? CGRect(origin: .zero, size: full)
        guard let cropped = image.cropping(to: crop) else { return nil }
        let size = fittedSize(width: cropped.width, height: cropped.height, maxEdge: maxEdge)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(cropped, in: canvas)
        if let shape, bounds(of: shape, imageSize: full) != nil {
            // 囲みの外側を暗くする(CGContext は左下が原点なので、上下を反転して描く)
            let scale = CGFloat(size.width) / crop.width
            let points = shape.map { CGPoint(x: ($0.x - crop.minX) * scale, y: CGFloat(size.height) - ($0.y - crop.minY) * scale) }
            context.addRect(canvas)
            context.addLines(between: points)
            context.closePath()
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: outsideDarkness))
            context.fillPath(using: .evenOdd)
        }
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 送る JPEG(切り出し・外側を暗く・縮小)
    static func prepare(_ image: CGImage, shape: [CGPoint]?, maxEdge: Int) -> Data? {
        render(image, shape: shape, maxEdge: maxEdge).flatMap { jpeg($0) }
    }

    /// 画像の入力のトークン数の目安(28×28 ピクセルごとに1トークン。Claude Haiku 5.5 は長い辺2576pxまで縮めない)
    static func estimatedTokens(width: Int, height: Int) -> Int {
        Int(ceil(Double(width) / 28)) * Int(ceil(Double(height) / 28))
    }
}
