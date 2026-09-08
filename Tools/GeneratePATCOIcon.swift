import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.42, green: 0.02, blue: 0.11, alpha: 1).setFill()
bounds.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.02, blue: 0.11, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1)
])!
gradient.draw(in: bounds, angle: -35)

NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.22, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 136, y: 192, width: 752, height: 592), xRadius: 78, yRadius: 78).fill()

NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 188, y: 244, width: 648, height: 488), xRadius: 58, yRadius: 58).fill()

NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 248, y: 512, width: 528, height: 132), xRadius: 28, yRadius: 28).fill()

NSColor(calibratedRed: 0.42, green: 0.02, blue: 0.11, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 250, y: 328, width: 210, height: 92), xRadius: 24, yRadius: 24).fill()
NSBezierPath(roundedRect: NSRect(x: 564, y: 328, width: 210, height: 92), xRadius: 24, yRadius: 24).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let patcoAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 126, weight: .black),
    .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.02, blue: 0.11, alpha: 1),
    .paragraphStyle: paragraph
]
"PATCO".draw(in: NSRect(x: 188, y: 530, width: 648, height: 150), withAttributes: patcoAttributes)

let nextAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 58, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph
]
"NEXT".draw(in: NSRect(x: 260, y: 438, width: 504, height: 80), withAttributes: nextAttributes)

NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.22, alpha: 1).setStroke()
let leftRail = NSBezierPath()
leftRail.lineWidth = 26
leftRail.move(to: NSPoint(x: 388, y: 164))
leftRail.line(to: NSPoint(x: 452, y: 248))
leftRail.stroke()

let rightRail = NSBezierPath()
rightRail.lineWidth = 26
rightRail.move(to: NSPoint(x: 636, y: 164))
rightRail.line(to: NSPoint(x: 572, y: 248))
rightRail.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render icon")
}

try png.write(to: output)
