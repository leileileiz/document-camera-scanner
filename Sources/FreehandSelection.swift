import SwiftUI

/// Normalized coordinates, measured from the upper left of the displayed image.
struct FreehandSelection: Sendable {
    let points: [CGPoint]

    init?(points: [CGPoint]) {
        guard points.count >= 3 else { return nil }
        let area = points.indices.reduce(CGFloat.zero) { sum, index in
            let a = points[index], b = points[(index + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        }
        guard abs(area) > 0.000001 else { return nil }
        self.points = points
    }

    var rotatedRight: Self? {
        Self(points: points.map { CGPoint(x: 1 - $0.y, y: $0.x) })
    }

    var boundingCrop: ManualCrop {
        ManualCrop(rect: path(in: CGSize(width: 1, height: 1)).boundingBox)
    }

    func path(in size: CGSize, flipped: Bool = false) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map {
            CGPoint(x: $0.x * size.width, y: (flipped ? 1 - $0.y : $0.y) * size.height)
        })
        path.closeSubpath()
        return path
    }

    func cropAndFillOutsideWhite(_ image: CGImage) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let imageBounds = CGRect(origin: .zero, size: size)
        let outline = path(in: size, flipped: true)
        let cropBounds = outline.boundingBox.integral.intersection(imageBounds)
        guard !cropBounds.isEmpty,
              let canvas = CGContext(data: nil, width: Int(cropBounds.width), height: Int(cropBounds.height),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScanProcessing.failure("无法创建圈选图片")
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(origin: .zero, size: cropBounds.size))
        canvas.translateBy(x: -cropBounds.minX, y: -cropBounds.minY)
        canvas.addPath(outline)
        canvas.clip(using: .evenOdd)
        canvas.draw(image, in: imageBounds)
        guard let result = canvas.makeImage() else { throw ScanProcessing.failure("无法生成圈选图片") }
        return result
    }
}

struct FreehandSelectionOverlay: View {
    @Binding var selection: FreehandSelection?
    let size: CGSize
    let editable: Bool
    @State private var stroke: [CGPoint] = []

    var body: some View {
        Canvas { context, size in
            if stroke.isEmpty, let selection {
                let outline = Path(selection.path(in: size))
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addPath(outline)
                context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                context.stroke(outline, with: .color(.yellow), lineWidth: 2)
            } else if let first = stroke.first {
                var line = Path()
                line.move(to: display(first))
                line.addLines(stroke.dropFirst().map(display))
                context.stroke(line, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                if stroke.isEmpty { stroke.append(normalized(value.startLocation)) }
                let next = normalized(value.location)
                if let last = stroke.last,
                   hypot((next.x - last.x) * size.width, (next.y - last.y) * size.height) >= 1.5 {
                    stroke.append(next)
                }
            }
            .onEnded { value in
                let points = stroke + [normalized(value.location)]
                if let newSelection = FreehandSelection(points: points) { selection = newSelection }
                stroke = []
            })
        .allowsHitTesting(editable)
        .accessibilityLabel("自由圈选预览")
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)),
                y: min(1, max(0, point.y / size.height)))
    }

    private func display(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
