import CoreGraphics
import ImageIO
import Foundation

for path in CommandLine.arguments.dropFirst() {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let provider = image.dataProvider, let data = provider.data else { continue }
  let bytes = CFDataGetBytePtr(data)!
  var minAlpha = 255, maxAlpha = 0
  for index in stride(from: 3, to: image.bytesPerRow * image.height, by: 4) {
    let alpha = Int(bytes[index]); minAlpha = min(minAlpha, alpha); maxAlpha = max(maxAlpha, alpha)
  }
  print("\(path): alphaMin=\(minAlpha) alphaMax=\(maxAlpha)")
}
