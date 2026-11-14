import CoreGraphics

/// Finds a light sheet on a dark background when rectangle detection misses it.
enum PaperContour {
    static func detect(_ image: CGImage) -> DocumentQuad? {
        let scale = 384.0 / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 0, count: width * height)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        let threshold = max(110, otsuThreshold(gray))
        var foreground = gray.map { Int($0) > threshold }
        var largest: [Int] = []
        var secondLargest = 0
        var component: [Int] = []
        for start in foreground.indices where foreground[start] {
            component.removeAll(keepingCapacity: true)
            foreground[start] = false
            component.append(start)
            var head = 0
            while head < component.count {
                let index = component[head]
                head += 1
                let x = index % width
                let y = index / width
                if x > 0 { enqueue(index - 1) }
                if x + 1 < width { enqueue(index + 1) }
                if y > 0 { enqueue(index - width) }
                if y + 1 < height { enqueue(index + width) }
            }
            if component.count > largest.count {
                secondLargest = largest.count
                swap(&largest, &component)
            } else {
                secondLargest = max(secondLargest, component.count)
            }
        }
        func enqueue(_ index: Int) {
            guard foreground[index] else { return }
            foreground[index] = false
            component.append(index)
        }
        guard largest.count >= width * height / 5, secondLargest * 4 < largest.count * 3 else { return nil }

        // The hull only needs the left and right endpoints of each occupied row.
        var left = [Int](repeating: width, count: height)
        var right = [Int](repeating: -1, count: height)
        for index in largest {
            let x = index % width
            let y = index / width
            guard x > 0, x + 1 < width, y > 0, y + 1 < height else { return nil }
            left[y] = min(left[y], x)
            right[y] = max(right[y], x)
        }
        let endpoints = left.indices.filter { right[$0] >= 0 }.flatMap { y in
            [CGPoint(x: left[y], y: y), CGPoint(x: right[y], y: y)]
        }
        var corners = hull(endpoints)
        guard corners.count >= 4 else { return nil }
        let hullArea = polygonArea(corners)
        while corners.count > 4 {
            // Remove the vertex whose removal changes the enclosed area least.
            let i = corners.indices.min { a, b in
                cornerArea(corners, at: a) < cornerArea(corners, at: b)
            }!
            corners.remove(at: i)
        }
        let quadArea = polygonArea(corners)
        guard quadArea >= hullArea * 0.93, Double(largest.count) >= hullArea * 0.68 else { return nil }

        let lengths = corners.indices.map { i in
            let a = corners[i], b = corners[(i + 1) % 4]
            return hypot(a.x - b.x, a.y - b.y)
        }
        let spanA = lengths[0] + lengths[2], spanB = lengths[1] + lengths[3]
        let aspect = min(spanA, spanB) / max(spanA, spanB)
        guard (0.53...0.88).contains(aspect),
              min(lengths[0], lengths[2]) >= 0.72 * max(lengths[0], lengths[2]),
              min(lengths[1], lengths[3]) >= 0.72 * max(lengths[1], lengths[3]) else { return nil }

        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        // On each side, most samples should cross from light paper to darker surroundings.
        let offset = max(3, min(width, height) / 40)
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % 4]
            let normal = CGPoint(x: -(b.y - a.y) / lengths[i], y: (b.x - a.x) / lengths[i])
            let supported = (1...11).filter { sample in
                let t = CGFloat(sample) / 12
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                let dx = normal.x * CGFloat(offset), dy = normal.y * CGFloat(offset)
                let inner = pixel(x + dx, y + dy)
                let outer = pixel(x - dx, y - dy)
                guard let inner, let outer else { return false }
                return inner > threshold && inner - outer >= 24
            }.count
            guard supported >= 7 else { return nil }
        }
        func pixel(_ x: CGFloat, _ y: CGFloat) -> Int? {
            let column = Int(x.rounded()), row = Int(y.rounded())
            guard (0..<width).contains(column), (0..<height).contains(row) else { return nil }
            return Int(gray[row * width + column])
        }

        let first = corners.indices.min { corners[$0].x + corners[$0].y < corners[$1].x + corners[$1].y }!
        let points = (0..<4).map { i -> CGPoint in
            let point = corners[(first + i) % 4]
            // Leave a narrow margin outside the measured edge to protect edge content.
            let x = point.x + (point.x - center.x) * 0.035
            let y = point.y + (point.y - center.y) * 0.035
            return CGPoint(x: min(1, max(0, (x + 0.5) / CGFloat(width))),
                           y: 1 - min(1, max(0, (y + 0.5) / CGFloat(height))))
        }
        let quad = DocumentQuad(topLeft: points[0], topRight: points[1],
                                bottomRight: points[2], bottomLeft: points[3])
        return quad.valid ? quad : nil
    }

    private static func otsuThreshold(_ pixels: [UInt8]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels { histogram[Int(pixel)] += 1 }
        let totalSum = histogram.indices.reduce(0) { $0 + $1 * histogram[$1] }
        var lowCount = 0, lowSum = 0
        var bestScore = 0.0
        var threshold = 0
        for value in histogram.indices {
            lowCount += histogram[value]
            lowSum += value * histogram[value]
            let highCount = pixels.count - lowCount
            guard lowCount > 0, highCount > 0 else { continue }
            let difference = Double(lowSum) / Double(lowCount) - Double(totalSum - lowSum) / Double(highCount)
            let score = Double(lowCount) * Double(highCount) * difference * difference
            if score > bestScore {
                bestScore = score
                threshold = value
            }
        }
        return threshold
    }

    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var edge: [CGPoint] = []
            for point in points {
                if edge.last == point { continue }
                while edge.count >= 2 && cross(edge[edge.count - 2], edge[edge.count - 1], point) <= 0 {
                    edge.removeLast()
                }
                edge.append(point)
            }
            return edge
        }
        return Array(half(sorted).dropLast()) + Array(half(Array(sorted.reversed())).dropLast())
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func cornerArea(_ points: [CGPoint], at i: Int) -> CGFloat {
        let count = points.count
        return cross(points[(i + count - 1) % count], points[i], points[(i + 1) % count])
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        points.indices.dropFirst().dropLast().reduce(CGFloat(0)) {
            $0 + cross(points[0], points[$1], points[$1 + 1]) / 2
        }
    }
}
