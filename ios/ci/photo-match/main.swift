// Tunes and checks PhotoMatch.threshold with Vision on the CI's Mac (the iOS Simulator has no working image feature
// prints: it returns all zeros). Built by the workflow together with GupDoKit's sources:
//   swiftc -swift-version 5 ../GupDoKit/Sources/GupDoKit/*.swift ci/photo-match/main.swift -o photo-match
//   ./photo-match Tests/Fixtures/PhotoMatch report.txt
// Every retake of a spot (another day, moved camera, other light; and the reference a step closer, tilted, darker)
// must be within the threshold of its reference; every other spot and room must be beyond it. Exit 1 otherwise.
import CoreGraphics
import Foundation
import ImageIO
import Vision

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: photo-match FIXTURES [REPORT]"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let spots = ["sink", "kitchen", "desk", "bedside"]
let others = (1...6).map { "other-\($0)" }

func load(_ name: String) -> CGImage {
    let url = dir.appendingPathComponent("\(name).jpg")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't read \(url.path)") }
    return image
}

func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    body(ctx)
    return ctx.makeImage()!
}

// Handheld differences: a step closer, tilted, darker.
func closer(_ i: CGImage) -> CGImage {
    let w = Int(Double(i.width) * 0.8), h = Int(Double(i.height) * 0.8)
    return i.cropping(to: CGRect(x: (i.width - w) / 2, y: (i.height - h) / 2, width: w, height: h))!
}

func tilted(_ i: CGImage) -> CGImage {
    draw(i.width, i.height) { c in
        c.translateBy(x: CGFloat(i.width) / 2, y: CGFloat(i.height) / 2)
        c.rotate(by: 5 * .pi / 180)
        c.scaleBy(x: 1.12, y: 1.12)
        c.draw(i, in: CGRect(x: -CGFloat(i.width) / 2, y: -CGFloat(i.height) / 2, width: CGFloat(i.width),
                             height: CGFloat(i.height)))
    }
}

func darker(_ i: CGImage) -> CGImage {
    draw(i.width, i.height) { c in
        c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
        c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
        c.fill(CGRect(x: 0, y: 0, width: i.width, height: i.height))
    }
}

var cache: [String: FeaturePrintObservation] = [:]
func fp(_ name: String, _ image: @autoclosure () -> CGImage) async throws -> FeaturePrintObservation {
    if let p = cache[name] { return p }
    let p = try await GenerateImageFeaturePrintRequest().perform(on: image(), orientation: .up)
    guard p.data.contains(where: { $0 != 0 }) else { print("Vision returned an empty feature print"); exit(3) }
    cache[name] = p
    return p
}

var same: [(String, Double)] = [], different: [(String, Double)] = []
for spot in spots {
    let ref = load("\(spot)-ref")
    let r = try await fp("\(spot)-ref", ref)
    let again = load("\(spot)-again-a")
    let probes: [(String, CGImage)] = [
        ("\(spot)-again-a", again), ("\(spot)-again-b", load("\(spot)-again-b")),
        ("\(spot)-ref closer", closer(ref)), ("\(spot)-ref tilted", tilted(ref)), ("\(spot)-ref darker", darker(ref)),
        ("\(spot)-again-a tilted", tilted(again)),
    ]
    for (name, image) in probes { same.append(("\(spot)-ref vs \(name)", try r.distance(to: try await fp(name, image)))) }
    for name in spots.filter({ $0 != spot }).flatMap({ ["\($0)-ref", "\($0)-again-a"] }) + others {
        different.append(("\(spot)-ref vs \(name)", try r.distance(to: try await fp(name, load(name)))))
    }
}

let f = { (v: Double) in String(format: "%.3f", v) }
let maxSame = same.map(\.1).max()!, minDifferent = different.map(\.1).min()!
var report = "PhotoMatch.threshold \(PhotoMatch.threshold): same spot at most \(f(maxSame)), other rooms at least "
    + "\(f(minDifferent)); midpoint \(f((maxSame + minDifferent) / 2))\n\nsame spot (must be <= threshold):\n"
for (n, v) in same.sorted(by: { $0.1 > $1.1 }) { report += "  \(f(v))  \(n)\n" }
report += "\nother rooms (must be > threshold):\n"
for (n, v) in different.sorted(by: { $0.1 < $1.1 }) { report += "  \(f(v))  \(n)\n" }
print(report)
if args.count >= 3 { try report.write(toFile: args[2], atomically: true, encoding: .utf8) }
let ok = maxSame <= PhotoMatch.threshold && minDifferent > PhotoMatch.threshold
print(ok ? "photo match: threshold separates them" : "photo match: FAILED, the threshold doesn't separate them")
exit(ok ? 0 : 1)
