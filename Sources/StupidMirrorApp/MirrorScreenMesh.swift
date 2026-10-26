import AppKit

/// Projected vertices from Device Hub's actual display mesh. Every vertex is
/// [x, y, u, v], normalized to the chassis and original framebuffer respectively.
struct MirrorScreenMesh: Codable, Equatable, Sendable {
    let vertices: [[Double]]
    let triangles: [Int]
    let frameAspectRatio: Double

    enum CodingKeys: String, CodingKey {
        case vertices, triangles
        case frameAspectRatio = "frame_aspect_ratio"
    }

    func screenPoint(_ point: CGPoint, clamped: Bool) -> CGPoint? {
        var nearest: CGPoint?
        var nearestDistance = Double.infinity
        for offset in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = vertices[triangles[offset]], b = vertices[triangles[offset + 1]], c = vertices[triangles[offset + 2]]
            let determinant = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            guard abs(determinant) > 1e-12 else { continue }
            let u = ((b[1] - c[1]) * (point.x - c[0]) + (c[0] - b[0]) * (point.y - c[1])) / determinant
            let v = ((c[1] - a[1]) * (point.x - c[0]) + (a[0] - c[0]) * (point.y - c[1])) / determinant
            let w = 1 - u - v
            if u >= -1e-6 && v >= -1e-6 && w >= -1e-6 {
                return CGPoint(x: min(max(u * a[2] + v * b[2] + w * c[2], 0), 1),
                               y: min(max(u * a[3] + v * b[3] + w * c[3], 0), 1))
            }
            if clamped {
                for (start, end) in [(a, b), (b, c), (c, a)] {
                    let dx = end[0] - start[0], dy = end[1] - start[1]
                    let length = dx * dx + dy * dy
                    let fraction = length > 0 ? min(max(((point.x - start[0]) * dx + (point.y - start[1]) * dy) / length, 0), 1) : 0
                    let distance = pow(start[0] + fraction * dx - point.x, 2) + pow(start[1] + fraction * dy - point.y, 2)
                    if distance < nearestDistance {
                        nearestDistance = distance
                        nearest = CGPoint(x: start[2] + fraction * (end[2] - start[2]),
                                          y: start[3] + fraction * (end[3] - start[3]))
                    }
                }
            }
        }
        return clamped ? nearest : nil
    }
}

