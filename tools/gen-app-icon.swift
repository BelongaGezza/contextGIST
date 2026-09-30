// Turns GIST's macOS icon artwork into the single full-bleed layer of
// contextGIST's AppIcon.icon. Run via tools/gen-app-icon.sh.
//
// Usage: swift gen-app-icon.swift <source.png> <out-fullbleed.png>
//
// The source is an opaque 1024×1024 PNG: GIST's rounded dark body (with its
// own corner shape and a blue glow) on a white background. macOS 26+ masks
// app icons itself and puts any icon that isn't full-bleed on a grey backing
// tile, so the output is an opaque square: body colour to the edges, with
// the artwork where it would sit on Apple's macOS icon grid (an 824 px body
// in a 1024 canvas). The system's mask then replaces GIST's corners.
//
// 1. Find the body: flood-fill from the canvas edges across light pixels
//    (max channel > passThreshold). Everything reached is outside the body;
//    the cream pages and white lens rim *inside* the body are never reached
//    because the dark body surrounds them.
// 2. Sample the body colour a few px in from its edge, and repaint
//    everything outside it, plus the 1–2 px anti-aliased edge the fill
//    can't reach, with that colour.
// 3. Scale and centre the body on the 824-in-1024 grid.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024
let bodySize = 824.0
// How light a pixel must be for the fill to pass through it. 48 reaches most
// of the way down the body's anti-aliased edge (the body is ~#241F22); 36
// leaks through the paper texture into the artwork (the fill-ratio check
// below catches that). The last `edgeBand` px are repainted regardless.
let passThreshold = 48
let edgeBand = 2

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: gen-app-icon.swift <source.png> <out-fullbleed.png>\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(args[1])") }
let w = image.width, h = image.height
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// RGBA8 in sRGB. The source is opaque, so premultiplied == straight.
var px = [UInt8](repeating: 0, count: w * h * 4)
px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// ── 1. Find the body ────────────────────────────────────────────────────────
// dist[i]: 0 = outside the body, 1...n = px inward from its edge (up to the
// depth the BFS below walks), Int.max = deeper inside.
var dist = [Int](repeating: Int.max, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let i = stack.popLast() {
    if dist[i] == 0 || max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) <= passThreshold { continue }
    dist[i] = 0
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}

var minX = w, minY = h, maxX = -1, maxY = -1, bodyCount = 0
for i in 0..<(w * h) where dist[i] != 0 {
    let x = i % w, y = i / w
    minX = min(minX, x); maxX = max(maxX, x)
    minY = min(minY, y); maxY = max(maxY, y)
    bodyCount += 1
}
guard maxX >= 0 else { fail("no icon body found (everything was background)") }
let bodyW = Double(maxX - minX + 1), bodyH = Double(maxY - minY + 1)
// A rounded square fills most of its bounding box. A low ratio means the
// fill leaked into the body through a light path from the edge.
let fillRatio = Double(bodyCount) / (bodyW * bodyH)
print(String(format: "body %.0fx%.0f at (%d,%d), fills %.0f%% of its box", bodyW, bodyH, minX, minY, fillRatio * 100))
guard fillRatio > 0.75 else { fail("body fill ratio \(fillRatio) too low: the fill leaked into the artwork") }

// ── 2. Sample the body colour and repaint outside + edge ────────────────────
var frontier = (0..<(w * h)).filter { dist[$0] == 0 }
for d in 1...(edgeBand + 4) {
    var next: [Int] = []
    for i in frontier {
        let x = i % w, y = i / w
        for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
        where n >= 0 && dist[n] == Int.max {
            dist[n] = d; next.append(n)
        }
    }
    frontier = next
}
var sum = [0, 0, 0], samples = 0
for i in 0..<(w * h) where dist[i] >= edgeBand + 2 && dist[i] <= edgeBand + 4 {
    sum[0] += Int(px[i * 4]); sum[1] += Int(px[i * 4 + 1]); sum[2] += Int(px[i * 4 + 2]); samples += 1
}
let body = sum.map { $0 / max(samples, 1) }
for i in 0..<(w * h) where dist[i] <= edgeBand {
    px[i * 4] = UInt8(body[0]); px[i * 4 + 1] = UInt8(body[1]); px[i * 4 + 2] = UInt8(body[2])
    px[i * 4 + 3] = 255
}
let repainted: CGImage = px.withUnsafeMutableBytes { buf in
    CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
              bytesPerRow: w * 4, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

// ── 3. Lay out on the macOS icon grid ───────────────────────────────────────
let scale = bodySize / max(bodyW, bodyH)
// CG's origin is bottom-left; body coordinates above are top-left.
let bodyCenterX = Double(minX) + bodyW / 2
let bodyCenterY = Double(h) - (Double(minY) + bodyH / 2)
let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                    bytesPerRow: canvas * 4, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
out.setFillColor(CGColor(srgbRed: Double(body[0]) / 255, green: Double(body[1]) / 255,
                         blue: Double(body[2]) / 255, alpha: 1))
out.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
out.draw(repainted, in: CGRect(x: Double(canvas) / 2 - bodyCenterX * scale,
                               y: Double(canvas) / 2 - bodyCenterY * scale,
                               width: Double(w) * scale, height: Double(h) * scale))
print(String(format: "scale %.3f → body %.0f px on a %d canvas", scale, bodySize, canvas))

guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fail("can't write \(args[2])")
}
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG encode failed") }
print("✓ wrote \(args[2])")
print("body colour: \(body[0]) \(body[1]) \(body[2])")
