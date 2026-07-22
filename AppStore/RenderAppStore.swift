import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvasSize = NSSize(width: 1320, height: 2868)
private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let captureDirectory = root.appendingPathComponent("AppStore/Captures")
private let outputDirectory = root.appendingPathComponent("AppStore/Final")

private struct FrameSpec {
    let number: String
    let eyebrow: String
    let titleLines: [(text: String, accent: Bool)]
    let accent: NSColor
    let capture: String
    let output: String
}

private let ink = NSColor(calibratedRed: 0.025, green: 0.028, blue: 0.036, alpha: 1)
private let paper = NSColor(calibratedRed: 0.965, green: 0.955, blue: 0.915, alpha: 1)

private let frames: [FrameSpec] = [
    FrameSpec(
        number: "01",
        eyebrow: "DOTDOT / HOME SCREEN",
        titleLines: [("tiny moments.", true), ("right on their", false), ("home screen.", false)],
        accent: NSColor(calibratedRed: 0.20, green: 0.42, blue: 1.00, alpha: 1),
        capture: "raw-widget-home.png",
        output: "01-home-screen.png"
    ),
    FrameSpec(
        number: "02",
        eyebrow: "DOTDOT / DOTS",
        titleLines: [("draw a", false), ("tiny hello.", true)],
        accent: NSColor(calibratedRed: 1.00, green: 0.29, blue: 0.59, alpha: 1),
        capture: "raw-dots.png",
        output: "02-tiny-hello.png"
    ),
    FrameSpec(
        number: "03",
        eyebrow: "DOTDOT / PHOTO + DUAL SHOT",
        titleLines: [("send the", false), ("whole moment.", true)],
        accent: NSColor(calibratedRed: 1.00, green: 0.76, blue: 0.05, alpha: 1),
        capture: "raw-photo.png",
        output: "03-whole-moment.png"
    ),
    FrameSpec(
        number: "04",
        eyebrow: "DOTDOT / DOODLE",
        titleLines: [("scribble it", false), ("your way.", true)],
        accent: NSColor(calibratedRed: 0.69, green: 0.98, blue: 0.06, alpha: 1),
        capture: "raw-doodle.png",
        output: "04-scribble.png"
    ),
    FrameSpec(
        number: "05",
        eyebrow: "DOTDOT / REACTIONS",
        titleLines: [("see it. react.", false), ("send one back.", true)],
        accent: NSColor(calibratedRed: 0.50, green: 0.53, blue: 1.00, alpha: 1),
        capture: "raw-reactions.png",
        output: "05-react.png"
    )
]

private func registerFont(at relativePath: String) -> String? {
    let url = root.appendingPathComponent(relativePath)
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    guard
        let dataProvider = CGDataProvider(url: url as CFURL),
        let cgFont = CGFont(dataProvider),
        let name = cgFont.postScriptName as String?
    else { return nil }
    return name
}

private let hankenName = registerFont(at: "Shared/Fonts/HankenGrotesk-VariableFont_wght.ttf")
private let monoBoldName = registerFont(at: "Shared/Fonts/SpaceMono-Bold.ttf")

private func titleFont(size: CGFloat) -> NSFont {
    guard let hankenName else { return .systemFont(ofSize: size, weight: .black) }
    let descriptor = NSFontDescriptor(name: hankenName, size: size)
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.black]])
    return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .black)
}

private func monoFont(size: CGFloat) -> NSFont {
    if let monoBoldName, let font = NSFont(name: monoBoldName, size: size) { return font }
    return .monospacedSystemFont(ofSize: size, weight: .bold)
}

private func makeImage(size: NSSize, drawing: () -> Void) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocusFlipped(true)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawing()
    image.unlockFocus()
    return image
}

private func writePNG(_ image: NSImage, to url: URL) throws {
    let width = Int(image.size.width)
    let height = Int(image.size.height)
    guard
        let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        throw NSError(domain: "DotdotRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create opaque image"])
    }
    context.setFillColor(ink.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard
        let flattened = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(domain: "DotdotRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DotdotRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not save PNG"])
    }
}

private func drawGlow(color: NSColor, rect: NSRect) {
    let gradient = NSGradient(starting: color.withAlphaComponent(0.34), ending: color.withAlphaComponent(0))
    gradient?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: 0, y: 0))
}

private func drawDotField(color: NSColor, origin: NSPoint) {
    for row in 0..<7 {
        for column in 0..<7 {
            let alpha = 0.07 + CGFloat(row + column) * 0.008
            color.withAlphaComponent(alpha).setFill()
            let size: CGFloat = (row + column).isMultiple(of: 3) ? 9 : 6
            NSBezierPath(ovalIn: NSRect(
                x: origin.x + CGFloat(column) * 30,
                y: origin.y + CGFloat(row) * 30,
                width: size,
                height: size
            )).fill()
        }
    }
}

private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
        .paragraphStyle: paragraph
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}

private func drawPill(number: String, accent: NSColor) {
    let rect = NSRect(x: 1120, y: 68, width: 104, height: 64)
    accent.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
    accent.withAlphaComponent(0.68).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 31, yRadius: 31)
    border.lineWidth = 2
    border.stroke()
    drawText(number, in: NSRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: 38), font: monoFont(size: 24), color: paper)
}

private func drawCapture(_ capture: NSImage, accent: NSColor) {
    let width: CGFloat = 1104
    let height = width * 2868 / 1320
    let rect = NSRect(x: 108, y: 692, width: width, height: height)
    let backingRect = rect.offsetBy(dx: 0, dy: 18)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = accent.withAlphaComponent(0.42)
    shadow.shadowBlurRadius = 72
    shadow.shadowOffset = NSSize(width: 0, height: 14)
    shadow.set()
    accent.withAlphaComponent(0.82).setFill()
    NSBezierPath(roundedRect: backingRect, xRadius: 84, yRadius: 84).fill()
    NSGraphicsContext.restoreGraphicsState()

    let clip = NSBezierPath(roundedRect: rect, xRadius: 76, yRadius: 76)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    capture.draw(
        in: rect,
        from: NSRect(origin: .zero, size: capture.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.16).setStroke()
    clip.lineWidth = 3
    clip.stroke()

    accent.setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 650, width: 72, height: 72), xRadius: 22, yRadius: 22).fill()
    paper.setFill()
    NSBezierPath(ovalIn: NSRect(x: 94, y: 674, width: 24, height: 24)).fill()
}

private func renderFrame(_ spec: FrameSpec) throws -> NSImage {
    let captureURL = captureDirectory.appendingPathComponent(spec.capture)
    guard let capture = NSImage(contentsOf: captureURL) else {
        throw NSError(domain: "DotdotRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing capture: \(captureURL.path)"])
    }

    return makeImage(size: canvasSize) {
        ink.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

        drawGlow(color: spec.accent, rect: NSRect(x: 760, y: -180, width: 900, height: 900))
        drawGlow(color: spec.accent, rect: NSRect(x: -520, y: 2050, width: 1120, height: 1120))
        drawDotField(color: spec.accent, origin: NSPoint(x: 1010, y: 185))

        drawText(spec.eyebrow, in: NSRect(x: 98, y: 82, width: 850, height: 50), font: monoFont(size: 25), color: paper.withAlphaComponent(0.72), tracking: 2.0)
        drawPill(number: spec.number, accent: spec.accent)

        let lineHeight: CGFloat = 116
        let titleY: CGFloat = 160
        for (index, line) in spec.titleLines.enumerated() {
            drawText(
                line.text,
                in: NSRect(x: 94, y: titleY + CGFloat(index) * lineHeight, width: 1134, height: 126),
                font: titleFont(size: 112),
                color: line.accent ? spec.accent : paper,
                tracking: -3.1
            )
        }

        let underlineY = titleY + CGFloat(spec.titleLines.count) * lineHeight + 10
        spec.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 98, y: underlineY, width: 168, height: 10), xRadius: 5, yRadius: 5).fill()
        paper.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: 278, y: underlineY, width: 50, height: 10), xRadius: 5, yRadius: 5).fill()

        drawCapture(capture, accent: spec.accent)
    }
}

private func renderContactSheet(finalImages: [NSImage]) -> NSImage {
    let size = NSSize(width: 1900, height: 980)
    return makeImage(size: size) {
        NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        drawText("DOTDOT / APP STORE STORY", in: NSRect(x: 86, y: 48, width: 1100, height: 62), font: monoFont(size: 30), color: ink, tracking: 2)
        drawText("five frames. one tiny way to stay close.", in: NSRect(x: 86, y: 100, width: 1300, height: 72), font: titleFont(size: 48), color: ink)

        let width: CGFloat = 318
        let height = width * 2868 / 1320
        let gap: CGFloat = 38
        let startX: CGFloat = 79
        for (index, image) in finalImages.enumerated() {
            let rect = NSRect(x: startX + CGFloat(index) * (width + gap), y: 205, width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = NSSize(width: 0, height: 8)
            shadow.set()
            image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var rendered: [NSImage] = []
for spec in frames {
    let image = try renderFrame(spec)
    try writePNG(image, to: outputDirectory.appendingPathComponent(spec.output))
    rendered.append(image)
}

let contactSheet = renderContactSheet(finalImages: rendered)
try writePNG(contactSheet, to: outputDirectory.appendingPathComponent("00-contact-sheet.png"))
print("Rendered \(rendered.count) App Store frames to \(outputDirectory.path)")
