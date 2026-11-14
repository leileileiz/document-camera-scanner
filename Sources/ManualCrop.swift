import SwiftUI

enum A4CropOrientation: String, CaseIterable, Identifiable {
    case portrait, landscape

    var id: Self { self }
    var title: String { self == .portrait ? "竖版" : "横版" }
    var aspectRatio: CGFloat { self == .portrait ? 210.0 / 297.0 : 297.0 / 210.0 }
}

/// Normalized in the displayed image, with the origin at its upper left.
struct ManualCrop: RawRepresentable, Sendable {
    let rect: CGRect
    static let minimumSide: CGFloat = 18
    static let initial = ManualCrop(rect: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8))

    init(rect: CGRect) { self.rect = rect }

    init?(rawValue: String) {
        let values = rawValue.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy({ $0.isFinite }),
              values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
              values[0] + values[2] <= 1.000001, values[1] + values[3] <= 1.000001 else { return nil }
        rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    var rawValue: String {
        [rect.minX, rect.minY, rect.width, rect.height].map { String(Double($0)) }.joined(separator: ",")
    }

    var rotatedRight: Self {
        Self(rect: CGRect(x: max(0, 1 - rect.maxY), y: rect.minX, width: rect.height, height: rect.width))
    }

    func inSource(rotation: Int) -> Self {
        var selection = self
        for _ in 0..<((4 - rotation % 4) % 4) { selection = selection.rotatedRight }
        return selection
    }

    func crop(_ image: CGImage) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = inImage(of: bounds.size).integral.intersection(bounds)
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }

    func inImage(of size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    func fitted(to aspectRatio: CGFloat, in size: CGSize) -> Self {
        let imageRect = inImage(of: size)
        guard abs(imageRect.width / imageRect.height - aspectRatio) > 0.000001 else { return self }
        let width = min(imageRect.width, imageRect.height * aspectRatio)
        let height = width / aspectRatio
        return Self(rect: CGRect(x: (imageRect.midX - width / 2) / size.width,
                                 y: (imageRect.midY - height / 2) / size.height,
                                 width: width / size.width, height: height / size.height))
    }

    func resizingLocked(by translation: CGSize, fromLeft: Bool, fromTop: Bool,
                        aspectRatio: CGFloat, in size: CGSize) -> Self {
        let imageRect = inImage(of: size)
        let anchor = CGPoint(x: fromLeft ? imageRect.maxX : imageRect.minX,
                             y: fromTop ? imageRect.maxY : imageRect.minY)
        let widthLimit = fromLeft ? anchor.x : size.width - anchor.x
        let heightLimit = fromTop ? anchor.y : size.height - anchor.y
        let maximumWidth = min(widthLimit, heightLimit * aspectRatio)
        let minimumWidth = min(imageRect.width, max(Self.minimumSide, Self.minimumSide * aspectRatio))
        let dx = translation.width * (fromLeft ? -1 : 1)
        let dy = translation.height * (fromTop ? -1 : 1)
        // Project the pointer movement onto the diagonal that preserves the ratio.
        let slope = 1 / aspectRatio
        let change = (dx + dy * slope) / (1 + slope * slope)
        let width = min(maximumWidth, max(minimumWidth, imageRect.width + change))
        let height = width / aspectRatio
        return Self(rect: CGRect(x: max(0, fromLeft ? anchor.x - width : anchor.x) / size.width,
                                 y: max(0, fromTop ? anchor.y - height : anchor.y) / size.height,
                                 width: width / size.width, height: height / size.height))
    }
}

struct ManualCropOverlay: View {
    @Binding var selection: ManualCrop
    let size: CGSize
    let editable: Bool
    let aspectRatio: CGFloat?
    @GestureState private var drag: ManualCrop?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var left: Bool { self == .topLeft || self == .bottomLeft }
        var top: Bool { self == .topLeft || self == .topRight }
    }

    var body: some View {
        let rect = (drag ?? selection).inImage(of: size)
        let handleSize = min(26, min(rect.width, rect.height) * 0.8)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }.fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Rectangle()
                .fill(.clear)
                .overlay { Rectangle().strokeBorder(.black.opacity(0.65), lineWidth: 4) }
                .overlay { Rectangle().strokeBorder(.yellow, lineWidth: 2) }
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveOrResize())
                .help("拖动框内移动位置")
            if editable {
                ForEach(Corner.allCases, id: \.self) { corner in
                    ZStack {
                        Circle().fill(.yellow)
                            .overlay { Circle().strokeBorder(.black.opacity(0.65), lineWidth: 1) }
                            .frame(width: min(13, handleSize), height: min(13, handleSize))
                    }
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Rectangle())
                    .position(x: corner.left ? rect.minX : rect.maxX, y: corner.top ? rect.minY : rect.maxY)
                    .gesture(moveOrResize(corner))
                    .help("拖动角点调整大小")
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "manual-crop-preview")
        .allowsHitTesting(editable)
    }

    private func moveOrResize(_ corner: Corner? = nil) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("manual-crop-preview"))
            .updating($drag) { value, state, _ in
                state = adjusted(by: value.translation, corner: corner)
            }
            .onEnded { value in
                selection = adjusted(by: value.translation, corner: corner)
            }
    }

    private func adjusted(by translation: CGSize, corner: Corner?) -> ManualCrop {
        let rect = selection.rect
        let dx = translation.width / size.width
        let dy = translation.height / size.height
        func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            min(upper, max(lower, value))
        }
        guard let corner else {
            return ManualCrop(rect: CGRect(
                x: clamp(rect.minX + dx, lower: 0, upper: max(0, 1 - rect.width)),
                y: clamp(rect.minY + dy, lower: 0, upper: max(0, 1 - rect.height)),
                width: rect.width, height: rect.height))
        }
        if let aspectRatio {
            return selection.resizingLocked(by: translation, fromLeft: corner.left, fromTop: corner.top,
                                            aspectRatio: aspectRatio, in: size)
        }
        let minWidth = min(rect.width, ManualCrop.minimumSide / size.width)
        let minHeight = min(rect.height, ManualCrop.minimumSide / size.height)
        let left = corner.left ? clamp(rect.minX + dx, lower: 0, upper: rect.maxX - minWidth) : rect.minX
        let right = corner.left ? rect.maxX : clamp(rect.maxX + dx, lower: rect.minX + minWidth, upper: 1)
        let top = corner.top ? clamp(rect.minY + dy, lower: 0, upper: rect.maxY - minHeight) : rect.minY
        let bottom = corner.top ? rect.maxY : clamp(rect.maxY + dy, lower: rect.minY + minHeight, upper: 1)
        return ManualCrop(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }
}
