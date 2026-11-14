import CoreGraphics
import CoreImage
import Foundation

enum TextDeskew {
    private struct InkPoint {
        let x: Double
        let y: Double
    }

    /// Measure the concentration of ink in rows after undoing a candidate slope.
    /// Bitmap rows increase downward, so a positive slope needs a positive Core Image rotation.
    static func angle(for image: CGImage) -> Double? {
        let scale = min(1, 520.0 / Double(max(image.width, image.height)))
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard width >= 120, height >= 120 else { return nil }
        var gray = [UInt8](repeating: 255, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(rect)
            bitmap.interpolationQuality = .medium
            bitmap.draw(image, in: rect)
            return true
        }
        guard rendered else { return nil }

        // Local vertical contrast suppresses slow illumination changes and solid dark areas.
        let radius = max(4, height / 65)
        let insetX = width / 12
        let insetY = max(radius, height / 12)
        var left: [InkPoint] = []
        var right: [InkPoint] = []
        for y in insetY..<(height - insetY) {
            for x in insetX..<(width - insetX) {
                let pixel = Int(gray[y * width + x])
                let above = Int(gray[(y - radius) * width + x])
                let below = Int(gray[(y + radius) * width + x])
                guard pixel < 194, (above + below) / 2 - pixel >= 27 else { continue }
                let point = InkPoint(x: Double(x) - Double(width) / 2, y: Double(y))
                if x < width / 2 { left.append(point) } else { right.append(point) }
            }
        }
        let area = width * height
        let total = left.count + right.count
        guard min(left.count, right.count) >= max(70, area / 1400), total < area / 7 else { return nil }

        func score(_ points: [InkPoint], degrees: Double) -> Double {
            let slope = tan(degrees * .pi / 180)
            var bins = [Double](repeating: 0, count: height + 2)
            for point in points {
                let row = point.y - point.x * slope
                let index = Int(floor(row))
                guard index >= 0, index + 1 < bins.count else { continue }
                let fraction = row - Double(index)
                bins[index] += 1 - fraction
                bins[index + 1] += fraction
            }
            var energy = 0.0
            for row in 1..<(bins.count - 1) {
                let sum = bins[row - 1] + 2 * bins[row] + bins[row + 1]
                energy += sum * sum
            }
            return energy
        }

        let points = left + right
        let candidates = (-16...16).map { Double($0) / 4 }
        let scores = candidates.map { score(points, degrees: $0) }
        guard let index = scores.indices.max(by: { scores[$0] < scores[$1] }),
              index > 0, index < scores.count - 1,
              abs(candidates[index]) >= 0.25,
              scores[index] > scores[16] * 1.08 else { return nil }

        let coarse = candidates[index]
        let fine = (-4...4).map { coarse + Double($0) * 0.05 }
        guard let best = fine.max(by: { score(points, degrees: $0) < score(points, degrees: $1) }),
              abs(best) >= 0.3 else { return nil }

        // Reject a skew inferred solely from one half of the page or a single strong graphic.
        for half in [left, right] {
            let local = candidates.max { score(half, degrees: $0) < score(half, degrees: $1) }
            guard let local, abs(local - best) <= 0.85,
                  score(half, degrees: best) > score(half, degrees: 0) * 1.015 else { return nil }
        }
        return best
    }

    static func corrected(_ image: CGImage, degrees: Double) -> CGImage? {
        let rotated = CIImage(cgImage: image).transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180))
        let bounds = rotated.extent.integral
        let paper = CIImage(color: .white).cropped(to: bounds)
        return ScanProcessing.context.createCGImage(rotated.composited(over: paper), from: bounds)
    }
}
