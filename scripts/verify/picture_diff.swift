// Compares two pictures of the compare run pixel by pixel, and writes a picture of their difference.
//
//     picture-diff <first.png> <second.png> <difference.png>
//
// It prints one line of JSON: the `width` and `height` of the difference picture in pixels, its `pixels`, how many
// of them `differ`, and the `box` around those as [left, top, right, bottom] in pixels from the top left corner,
// which is null when none differs. A pixel differs when one of its four channels has another value in the two
// pictures, or when only one picture has it, because the pictures have different sizes. The difference picture
// shows a pixel that differs in magenta, and the others as a pale grey copy of the first picture, so the reader
// sees where a difference is. scripts/verify/compare.py builds this file once (`swift_helper` in sandbox.py).

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The picture as RGBA bytes, four for each pixel, from its top row.
func pixels(of path: String) -> (bytes: [UInt8], width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read the picture \(path)") }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drawn else { fail("cannot draw the picture \(path)") }
    return (bytes, image.width, image.height)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: picture-diff <first.png> <second.png> <difference.png>") }
let first = pixels(of: arguments[1]), second = pixels(of: arguments[2])
let width = max(first.width, second.width), height = max(first.height, second.height)
var difference = [UInt8](repeating: 255, count: width * height * 4)
var differ = 0
var left = width, top = height, right = 0, bottom = 0
for y in 0..<height {
    for x in 0..<width {
        let inFirst = x < first.width && y < first.height, inSecond = x < second.width && y < second.height
        let i = inFirst ? (y * first.width + x) * 4 : 0, j = inSecond ? (y * second.width + x) * 4 : 0
        let same = inFirst && inSecond && first.bytes[i] == second.bytes[j] && first.bytes[i + 1] == second.bytes[j + 1]
            && first.bytes[i + 2] == second.bytes[j + 2] && first.bytes[i + 3] == second.bytes[j + 3]
        let at = (y * width + x) * 4
        if same {
            // The first picture over white, in grey, at a quarter of its strength. Its colours hold its alpha already.
            let white = 255 - Int(first.bytes[i + 3])
            let grey = ((Int(first.bytes[i]) + white) * 3 + (Int(first.bytes[i + 1]) + white) * 6 + Int(first.bytes[i + 2]) + white) / 10
            let pale = UInt8(255 - (255 - grey) / 4)
            difference[at] = pale
            difference[at + 1] = pale
            difference[at + 2] = pale
        } else {
            differ += 1
            left = min(left, x)
            top = min(top, y)
            right = max(right, x + 1)
            bottom = max(bottom, y + 1)
            difference[at] = 255
            difference[at + 1] = 0
            difference[at + 2] = 255
        }
    }
}

let written = difference.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}
guard written else { fail("cannot write the picture \(arguments[3])") }
let box = differ == 0 ? "null" : "[\(left), \(top), \(right), \(bottom)]"
print("{\"width\": \(width), \"height\": \(height), \"pixels\": \(width * height), \"differ\": \(differ), \"box\": \(box)}")
