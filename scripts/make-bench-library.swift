// A large library for the scroll benchmark (Sources/LoupeUI/Grid/ScrollBenchmark.swift): N JPEG photos (1200×900,
// varied colours, EXIF dates spread over 3 years) in Photos/<year>/<day> folders.
//   swiftc -O scripts/make-bench-library.swift -o /tmp/make-bench-library && /tmp/make-bench-library /tmp/bench-lib 3000
//   SWIFT_FLAGS="-Xswiftc -DLOUPE_BENCH" scripts/bundle.sh release
//   open -n -W build/Loupe.app --args -LoupeRoot /tmp/bench-lib -LoupeScrollBenchmark /tmp/bench.txt -LoupeBenchColumns 15
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let count = Int(CommandLine.arguments[2]) ?? 3000
var rng = SystemRandomNumberGenerator()
let start = Date(timeIntervalSince1970: 1_640_000_000)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let formatter = DateFormatter()
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
let dayFormat = DateFormatter()
dayFormat.dateFormat = "yyyy/yyyy-MM-dd"
for i in 0..<count {
    let date = start.addingTimeInterval(Double(i) * 3 * 365 * 86400 / Double(count))
    let w = 1200, h = 900
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func color() -> CGColor { CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1) }
    let gradient = CGGradient(colorsSpace: space, colors: [color(), color()] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
    for _ in 0..<6 {
        ctx.setFillColor(color())
        ctx.fillEllipse(in: CGRect(x: .random(in: 0..<w, using: &rng), y: .random(in: 0..<h, using: &rng), width: .random(in: 50...500, using: &rng), height: .random(in: 50...500, using: &rng)))
    }
    let image = ctx.makeImage()!
    let folder = out.appendingPathComponent("Photos").appendingPathComponent(dayFormat.string(from: date))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(String(format: "IMG_%05d.jpg", i))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)]]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("wrote \(count) photos to \(out.path)")
