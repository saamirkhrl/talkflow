// Draws the background of the talkflow installer window (the DMG): an arrow
// from the app icon to the Applications folder and one instruction line.
// Run by release.sh; nothing it makes is committed.
//
//   swift scripts/dmg-background.swift <out-dir> <width> <height> <appX> <appY> <applicationsX> <applicationsY>
//
// Sizes are in points and measured from the top-left of the window's content
// area (the same numbers Finder uses for icon positions). Writes
// <out-dir>/background.png (1x) and <out-dir>/background@2x.png (2x, 144 dpi);
// release.sh joins them into a multi-resolution TIFF so Retina screens are sharp.
import AppKit

let args = CommandLine.arguments
guard args.count == 8, let width = Double(args[2]), let height = Double(args[3]),
      let appX = Double(args[4]), let appY = Double(args[5]),
      let applicationsX = Double(args[6]), let applicationsY = Double(args[7]) else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <out-dir> <width> <height> <appX> <appY> <applicationsX> <applicationsY>\n".utf8))
    exit(2)
}
let outDir = args[1]

// The app's look: paper background, ink text.
let paper = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF3 / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x1F / 255.0, green: 0x1E / 255.0, blue: 0x22 / 255.0, alpha: 1)

// Distance from an icon's center to where the arrow starts or stops: past the
// icon (128 pt, so 64 to its edge) with some air, so the arrow never touches it.
let gap = 84.0

func render(scale: Int, to path: String) {
    let pixelsWide = Int(width) * scale
    let pixelsHigh = Int(height) * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("could not create a \(pixelsWide)x\(pixelsHigh) bitmap")
    }
    // Pixels at scale x, point size fixed: that is what makes it 72 or 144 dpi.
    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no graphics context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Drawing space is bottom-left origin; the numbers we are given are from the top.
    let arrowY = height - appY

    // Instruction line, centered near the top.
    let font = NSFont(name: "Georgia", size: 30) ?? NSFont.systemFont(ofSize: 30)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let heading = NSAttributedString(string: "Drag talkflow to Applications", attributes: [
        .font: font, .foregroundColor: ink, .paragraphStyle: style, .kern: 0.2,
    ])
    let headingHeight = ceil(heading.size().height)
    heading.draw(in: NSRect(x: 0, y: height - 56 - headingHeight, width: width, height: headingHeight))

    // Thin arrow between the two icons.
    let startX = appX + gap
    let endX = applicationsX - gap
    ink.withAlphaComponent(0.55).setStroke()
    let shaft = NSBezierPath()
    shaft.lineWidth = 1.25
    shaft.lineCapStyle = .round
    shaft.lineJoinStyle = .round
    shaft.move(to: NSPoint(x: startX, y: arrowY))
    shaft.line(to: NSPoint(x: endX, y: arrowY))
    shaft.stroke()
    let head = NSBezierPath()
    head.lineWidth = 1.25
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: endX - 11, y: arrowY + 8))
    head.line(to: NSPoint(x: endX, y: arrowY))
    head.line(to: NSPoint(x: endX - 11, y: arrowY - 8))
    head.stroke()

    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode PNG") }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("could not write \(path): \(error)") }
}

render(scale: 1, to: "\(outDir)/background.png")
render(scale: 2, to: "\(outDir)/background@2x.png")
