import AppKit
import CoreGraphics

struct IconSlot {
    let filename: String
    let pixels: Int
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

let slots: [IconSlot] = [
    IconSlot(filename: "icon-20.png", pixels: 20),
    IconSlot(filename: "icon-20@2x.png", pixels: 40),
    IconSlot(filename: "icon-20@3x.png", pixels: 60),
    IconSlot(filename: "icon-29.png", pixels: 29),
    IconSlot(filename: "icon-29@2x.png", pixels: 58),
    IconSlot(filename: "icon-29@3x.png", pixels: 87),
    IconSlot(filename: "icon-40.png", pixels: 40),
    IconSlot(filename: "icon-40@2x.png", pixels: 80),
    IconSlot(filename: "icon-40@3x.png", pixels: 120),
    IconSlot(filename: "icon-60@2x.png", pixels: 120),
    IconSlot(filename: "icon-60@3x.png", pixels: 180),
    IconSlot(filename: "icon-76.png", pixels: 76),
    IconSlot(filename: "icon-76@2x.png", pixels: 152),
    IconSlot(filename: "icon-83.5@2x.png", pixels: 167),
    IconSlot(filename: "patco-next-icon.png", pixels: 1024)
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func drawRoundedRect(_ context: CGContext, rect: CGRect, radius: CGFloat, fill: NSColor) {
    context.setFillColor(fill.cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func drawText(_ text: String, in rect: CGRect, context: CGContext, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping

    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: fontSize * 0.01
    ]

    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    let target = CGRect(
        x: rect.minX,
        y: rect.midY - textSize.height / 2,
        width: rect.width,
        height: textSize.height
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    attributed.draw(in: target)
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(size: Int, destination: URL) throws {
    let scale = CGFloat(size) / 1024
    let width = CGFloat(size)
    let height = CGFloat(size)

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "PATCOIcon", code: 1)
    }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            color(128, 15, 38).cgColor,
            color(54, 24, 42).cgColor,
            color(16, 25, 31).cgColor
        ] as CFArray,
        locations: [0, 0.52, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: width, y: 0),
        options: []
    )

    let gold = color(255, 197, 71)
    let ivory = color(250, 249, 243)
    let charcoal = color(18, 27, 34)
    let wine = color(145, 13, 39)

    context.saveGState()
    context.setStrokeColor(gold.withAlphaComponent(0.28).cgColor)
    context.setLineWidth(26 * scale)
    context.move(to: CGPoint(x: 128 * scale, y: 172 * scale))
    context.addLine(to: CGPoint(x: 880 * scale, y: 892 * scale))
    context.strokePath()
    context.move(to: CGPoint(x: 230 * scale, y: 100 * scale))
    context.addLine(to: CGPoint(x: 956 * scale, y: 790 * scale))
    context.strokePath()
    context.restoreGState()

    let badge = CGRect(x: 134 * scale, y: 136 * scale, width: 756 * scale, height: 752 * scale)
    drawRoundedRect(context, rect: badge, radius: 174 * scale, fill: gold)

    let inner = badge.insetBy(dx: 62 * scale, dy: 62 * scale)
    drawRoundedRect(context, rect: inner, radius: 128 * scale, fill: charcoal)

    let window = CGRect(x: 275 * scale, y: 516 * scale, width: 474 * scale, height: 146 * scale)
    drawRoundedRect(context, rect: window, radius: 48 * scale, fill: ivory)

    drawText("PATCO", in: CGRect(x: 238 * scale, y: 380 * scale, width: 548 * scale, height: 142 * scale), context: context, fontSize: 134 * scale, weight: .heavy, color: ivory)

    drawRoundedRect(context, rect: CGRect(x: 282 * scale, y: 304 * scale, width: 170 * scale, height: 90 * scale), radius: 32 * scale, fill: wine)
    drawRoundedRect(context, rect: CGRect(x: 572 * scale, y: 304 * scale, width: 170 * scale, height: 90 * scale), radius: 32 * scale, fill: wine)

    context.setStrokeColor(gold.cgColor)
    context.setLineWidth(22 * scale)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 414 * scale, y: 210 * scale))
    context.addLine(to: CGPoint(x: 474 * scale, y: 292 * scale))
    context.strokePath()
    context.move(to: CGPoint(x: 610 * scale, y: 292 * scale))
    context.addLine(to: CGPoint(x: 670 * scale, y: 210 * scale))
    context.strokePath()

    context.setStrokeColor(ivory.withAlphaComponent(0.95).cgColor)
    context.setLineWidth(10 * scale)
    context.move(to: CGPoint(x: 356 * scale, y: 688 * scale))
    context.addLine(to: CGPoint(x: 668 * scale, y: 688 * scale))
    context.strokePath()

    guard let image = context.makeImage(),
          let destinationHandle = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "PATCOIcon", code: 2)
    }

    CGImageDestinationAddImage(destinationHandle, image, nil)
    if !CGImageDestinationFinalize(destinationHandle) {
        throw NSError(domain: "PATCOIcon", code: 3)
    }
}

for slot in slots {
    try drawIcon(size: slot.pixels, destination: outputDirectory.appendingPathComponent(slot.filename))
}
