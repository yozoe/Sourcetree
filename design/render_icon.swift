import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/Runner/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func drawIcon(size: Int) -> CGImage? {
  guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  let scale = CGFloat(size) / 1024
  context.scaleBy(x: scale, y: scale)
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  let bounds = CGRect(x: 92, y: 92, width: 840, height: 840)
  let surface = CGPath(
    roundedRect: bounds,
    cornerWidth: 188,
    cornerHeight: 188,
    transform: nil
  )

  // A soft shadow gives the tile the compact, raised macOS Dock presence used
  // by classic desktop Git clients while keeping the perimeter transparent.
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: 24),
    blur: 28,
    color: CGColor(red: 0.01, green: 0.06, blue: 0.18, alpha: 0.55)
  )
  context.setFillColor(CGColor(red: 0.03, green: 0.28, blue: 0.88, alpha: 1))
  context.addPath(surface)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(surface)
  context.clip()
  let colors = [
    CGColor(red: 0.12, green: 0.42, blue: 1, alpha: 1),
    CGColor(red: 0.02, green: 0.27, blue: 0.91, alpha: 1),
    CGColor(red: 0.01, green: 0.18, blue: 0.69, alpha: 1),
  ] as CFArray
  context.drawLinearGradient(
    CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      colors: colors,
      locations: [0, 0.56, 1]
    )!,
    start: CGPoint(x: 512, y: 94),
    end: CGPoint(x: 512, y: 934),
    options: []
  )

  context.restoreGState()

  let white = CGColor(red: 0.97, green: 0.99, blue: 1, alpha: 1)

  // The reference uses a generously sized central mark. Scale the complete
  // mark as one unit so its nodes, counters, trunk, and branch remain aligned
  // while the surrounding blue tile and transparent Dock margin stay intact.
  context.saveGState()
  context.translateBy(x: 512, y: 512)
  context.scaleBy(x: 1.22, y: 1.22)
  context.translateBy(x: -512, y: -512)

  // Original Git mark: one primary commit flows into a short trunk and a
  // smaller side commit. Draw all white parts in one flat pass so overlapping
  // geometry remains a continuous shape with no internal shadow seam.
  context.setStrokeColor(white)
  context.setLineWidth(92)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  let trunk = CGMutablePath()
  trunk.move(to: CGPoint(x: 500, y: 447))
  trunk.addLine(to: CGPoint(x: 500, y: 704))
  context.addPath(trunk)
  context.strokePath()

  let branch = CGMutablePath()
  branch.move(to: CGPoint(x: 500, y: 556))
  branch.addCurve(
    to: CGPoint(x: 655, y: 650),
    control1: CGPoint(x: 500, y: 612),
    control2: CGPoint(x: 576, y: 650)
  )
  context.addPath(branch)
  context.strokePath()

  context.setFillColor(white)
  context.fillEllipse(in: CGRect(x: 370, y: 258, width: 260, height: 260))
  context.fillEllipse(in: CGRect(x: 593, y: 588, width: 124, height: 124))

  // Blue counters keep both commits legible down to the 16 px rendition.
  context.setFillColor(CGColor(red: 0.03, green: 0.30, blue: 0.91, alpha: 1))
  context.fillEllipse(in: CGRect(x: 447, y: 335, width: 106, height: 106))
  context.fillEllipse(in: CGRect(x: 631, y: 626, width: 48, height: 48))
  context.restoreGState()

  context.setStrokeColor(
    CGColor(red: 0.68, green: 0.83, blue: 1, alpha: 0.45)
  )
  context.setLineWidth(3)
  context.addPath(surface)
  context.strokePath()

  // Keep at least one fully transparent pixel even in the 16 px rendition;
  // the soft tile shadow must never become an opaque canvas matte.
  context.clear(CGRect(x: 0, y: 0, width: 1024, height: 56))
  context.clear(CGRect(x: 0, y: 968, width: 1024, height: 56))
  context.clear(CGRect(x: 0, y: 0, width: 56, height: 1024))
  context.clear(CGRect(x: 968, y: 0, width: 56, height: 1024))
  return context.makeImage()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
  guard let image = drawIcon(size: size), let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outputDirectory)/icon_\(size).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
  CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
