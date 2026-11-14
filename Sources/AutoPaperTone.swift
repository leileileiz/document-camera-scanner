import CoreImage

enum AutoPaperTone {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: sRGB, .outputColorSpace: sRGB, .cacheIntermediates: false
    ])
    private static let kernel = CIColorKernel(source: """
        kernel vec4 paperTone(__sample source, float paper, float lift) {
            float luma = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
            float shadowWeight = clamp((luma - 0.22) / (paper - 0.22), 0.0, 1.0);
            float highlightWeight = clamp((1.0 - luma) / (1.0 - paper), 0.0, 1.0);
            float delta = lift * shadowWeight * highlightWeight;
            float room = 1.0 - max(source.r, max(source.g, source.b));
            return vec4(source.rgb + min(delta, max(0.0, room)), source.a);
        }
        """)

    static func brighten(_ image: CGImage) throws -> CGImage? {
        let input = CIImage(cgImage: image)
        // Sample within the page so padding and the edge of the desk don't set the white level.
        let region = input.extent.insetBy(dx: input.extent.width * 0.10, dy: input.extent.height * 0.10)
        let side = 128
        let sample = input.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / region.width,
                                               y: CGFloat(side) / region.height))
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            context.render(sample, toBitmap: address, rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side),
                           format: .RGBA8, colorSpace: sRGB)
        }
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] >= 250 {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            guard max(r, g, b) - min(r, g, b) < 38 else { continue }
            histogram[(54 * r + 183 * g + 19 * b + 128) / 256] += 1
        }
        let count = histogram.reduce(0, +)
        guard count >= side * side / 3 else { return nil }
        var cumulative = 0
        guard let white = histogram.indices.first(where: { level in
            cumulative += histogram[level]
            return cumulative * 100 >= count * 76
        }), (128..<243).contains(white) else { return nil }
        let paper = Double(white) / 255
        let lift = min(0.20, 0.956 - paper)
        guard let kernel,
              let adjusted = kernel.apply(extent: input.extent, arguments: [input, paper, lift]),
              let result = context.createCGImage(adjusted, from: input.extent) else {
            throw ScanProcessing.failure("无法应用自动亮度／对比度")
        }
        return result
    }
}
