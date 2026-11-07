import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
func chunk(_ type: String, _ bytes: Data) -> Data {
    var size = UInt32(bytes.count + 8).bigEndian
    return Data(type.utf8) + withUnsafeBytes(of: &size) { Data($0) } + bytes
}
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let palette = [
    CGColor(srgbRed: 0.12, green: 0.28, blue: 0.79, alpha: 1),
    CGColor(srgbRed: 0.34, green: 0.19, blue: 0.88, alpha: 1)
]
var icons = Data()
for (pixels, type) in [(16,"icp4"),(32,"icp5"),(64,"icp6"),(128,"ic07"),(256,"ic08"),(512,"ic09"),(1024,"ic10")] {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 88, y: 88, width: 848, height: 848),
                      cornerWidth: 200, cornerHeight: 200, transform: nil)
    c.saveGState()
    c.addPath(tile)
    c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: palette as CFArray, locations: [0,1])!,
                         start: CGPoint(x: 130, y: 920), end: CGPoint(x: 940, y: 180),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
    c.setLineWidth(22)
    c.strokeEllipse(in: CGRect(x: 303, y: 303, width: 418, height: 418))
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.64))
    c.setLineDash(phase: 0, lengths: [17,24])
    c.strokeEllipse(in: CGRect(x: 245, y: 245, width: 534, height: 534))
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.beginPath()
    c.move(to: CGPoint(x: 466, y: 590))
    c.addLine(to: CGPoint(x: 593, y: 512))
    c.addLine(to: CGPoint(x: 466, y: 434))
    c.closePath()
    c.fillPath()
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
    icons.append(chunk(type, png as Data))
}
try chunk("icns", icons).write(to: output)
