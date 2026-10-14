import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let coverage: CGFloat = 0.82

// A hadron: three quarks, one of each colour charge, bound by a Y-shaped gluon string
// inside the hadron's boundary.
let bagRadius: CGFloat = 430
let bagWidth: CGFloat = 46
let quarkOrbit: CGFloat = 228
let quarkRadius: CGFloat = 118
let stringWidth: CGFloat = 54
let junctionRadius: CGFloat = 58
let quarkAngles: [CGFloat] = [90, 210, 330]

enum Element: String, CaseIterable {
    case bag = "Bag"
    case strings = "Strings"
    case quarkRed = "Quark Red"
    case quarkGreen = "Quark Green"
    case quarkBlue = "Quark Blue"

    var fileName: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"
    }

    var fill: String {
        switch self {
        case .bag, .strings: "srgb:1.00000,1.00000,1.00000,1.00000"
        case .quarkRed: "srgb:1.00000,0.27059,0.34118,1.00000"
        case .quarkGreen: "srgb:0.18824,0.85882,0.48627,1.00000"
        case .quarkBlue: "srgb:0.25098,0.58824,1.00000,1.00000"
        }
    }
}

func quarkCenter(_ index: Int) -> CGPoint {
    let angle = quarkAngles[index] * .pi / 180
    return CGPoint(x: center.x + quarkOrbit * cos(angle), y: center.y + quarkOrbit * sin(angle))
}

func makeContext(size: CGFloat) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func circle(_ radius: CGFloat) -> CGRect {
    CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )
}

func draw(_ element: Element, into context: CGContext) {
    context.setStrokeColor(white)
    context.setFillColor(white)

    switch element {
    case .bag:
        context.setLineWidth(bagWidth)
        context.strokeEllipse(in: circle(bagRadius))

    case .strings:
        context.setLineWidth(stringWidth)
        context.setLineCap(.round)
        for index in quarkAngles.indices {
            context.move(to: center)
            context.addLine(to: quarkCenter(index))
        }
        context.strokePath()
        context.fillEllipse(in: circle(junctionRadius))

    case .quarkRed, .quarkGreen, .quarkBlue:
        let index = [Element.quarkRed, .quarkGreen, .quarkBlue].firstIndex(of: element)!
        let at = quarkCenter(index)
        context.fillEllipse(in: CGRect(x: at.x - quarkRadius, y: at.y - quarkRadius,
                                       width: quarkRadius * 2, height: quarkRadius * 2))
    }
}

func render(_ elements: [Element]) -> CGImage {
    let context = makeContext(size: canvas)
    for element in elements {
        draw(element, into: context)
    }
    return context.makeImage()!
}

func inkBounds(_ image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let scan = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        scan.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }
    return CGRect(
        x: CGFloat(minX),
        y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
    )
}

func normalized(_ image: CGImage, sharedInk ink: CGRect) -> CGImage {
    let scale = canvas * coverage / max(ink.width, ink.height)
    let context = makeContext(size: canvas)
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -ink.midX, y: -ink.midY)
    context.draw(image, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

func layer(_ element: Element) -> [String: Any] {
    ["fill": ["solid": element.fill], "image-name": element.fileName, "name": element.rawValue]
}

// Back to front: the boundary, the string, the quarks on top.
let groups: [(name: String, elements: [Element], depth: Double, translucency: Double)] = [
    ("Bag", [.bag], 0.40, 0.35),
    ("Strings", [.strings], 0.70, 0.30),
    ("Quarks", [.quarkRed, .quarkGreen, .quarkBlue], 1.00, 0.15),
]

func group(_ entry: (name: String, elements: [Element], depth: Double, translucency: Double)) -> [String: Any] {
    [
        "blur-material": NSNull(),
        "layers": entry.elements.map(layer),
        "name": entry.name,
        "opacity": 1,
        "refractivity": ["depth": entry.depth, "enabled": true, "strength": 0.005],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "specular": "inside",
        "translucency": ["enabled": true, "value": entry.translucency],
    ]
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: icon <output.icon>\n".data(using: .utf8)!)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let sharedInk = inkBounds(render(Element.allCases))
for element in Element.allCases {
    let layer = normalized(render([element]), sharedInk: sharedInk)
    try write(layer, to: assets.appendingPathComponent(element.fileName))
}

let document: [String: Any] = [
    "features": ["refractivity", "specular-location"],
    "fill": [
        "linear-gradient": [
            "srgb:0.20392,0.17647,0.45098,1.00000",
            "srgb:0.06667,0.05882,0.17647,1.00000",
        ]
    ],
    "groups": groups.reversed().map(group),
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]
try JSONSerialization
    .data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("icon.json"))
