import AppKit
import CoreText

// Design proposals only. Never edits the app bundle, input sources, or preferences.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

struct Concept {
    let id: String
    let file: String
    let title: String
    let subtitle: String
    let paths: [CGPath]
}

func glyph(_ text: String, in box: CGRect, font: NSFont) -> CGPath {
    let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    let characters = Array(text.utf16)
    var glyphs = Array(repeating: CGGlyph(), count: characters.count)
    precondition(CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count))
    let combined = CGMutablePath()
    var cursor: CGFloat = 0
    for var item in glyphs {
        if let outline = CTFontCreatePathForGlyph(ctFont, item, nil) {
            let position = CGAffineTransform(translationX: cursor, y: 0)
            combined.addPath(outline, transform: position)
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &item, &advance, 1)
        cursor += advance.width
    }
    let bounds = combined.boundingBoxOfPath
    let scale = min(box.width / bounds.width, box.height / bounds.height)
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
        tx: box.midX - bounds.midX * scale, ty: box.midY + bounds.midY * scale)
    return combined.copy(using: &transform)!
}

func stroke(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
}

func spark(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x, y: y - radius))
    path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x + 0.5, y: y - 0.5))
    path.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x + 0.5, y: y + 0.5))
    path.addQuadCurve(to: CGPoint(x: x - radius, y: y), control: CGPoint(x: x - 0.5, y: y + 0.5))
    path.addQuadCurve(to: CGPoint(x: x, y: y - radius), control: CGPoint(x: x - 0.5, y: y - 0.5))
    path.closeSubpath()
    return path
}

let kanaFont = NSFont(name: "HiraginoSans-W6", size: 24)!
let latinFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
let monogram = CGMutablePath()
monogram.move(to: CGPoint(x: 2.5, y: 14.5))
monogram.addLine(to: CGPoint(x: 2.5, y: 3.5))
monogram.addLine(to: CGPoint(x: 9, y: 10.5))
monogram.addLine(to: CGPoint(x: 15.5, y: 3.5))
monogram.addLine(to: CGPoint(x: 15.5, y: 14.5))

let loop = CGMutablePath()
loop.move(to: CGPoint(x: 9, y: 9))
loop.addCurve(to: CGPoint(x: 2, y: 9), control1: CGPoint(x: 5.5, y: 2.1), control2: CGPoint(x: 2, y: 4.5))
loop.addCurve(to: CGPoint(x: 9, y: 9), control1: CGPoint(x: 2, y: 13.5), control2: CGPoint(x: 5.5, y: 15.9))
loop.addCurve(to: CGPoint(x: 16, y: 9), control1: CGPoint(x: 12.5, y: 2.1), control2: CGPoint(x: 16, y: 4.5))
loop.addCurve(to: CGPoint(x: 9, y: 9), control1: CGPoint(x: 16, y: 13.5), control2: CGPoint(x: 12.5, y: 15.9))

let concepts = [
    Concept(id: "A", file: "a-bilingual", title: "あA", subtitle: "日英がひとつに。意味が伝わる。", paths: [
        glyph("あ", in: CGRect(x: 0.6, y: 1.0, width: 10.8, height: 11.5), font: kanaFont),
        glyph("A", in: CGRect(x: 10.0, y: 8.2, width: 7.6, height: 8.8), font: latinFont)
    ]),
    Concept(id: "B", file: "b-kana-spark", title: "かな＋きらめき", subtitle: "日本語を軸に、自動でおまかせ。", paths: [
        glyph("あ", in: CGRect(x: 0.8, y: 3.3, width: 13.8, height: 13.8), font: kanaFont),
        spark(x: 15.0, y: 3.0, radius: 2.4)
    ]),
    Concept(id: "C", file: "c-mixed-monogram", title: "Mixed の M", subtitle: "簡潔で、アプリの目印になる。", paths: [stroke(monogram, width: 2.05)]),
    Concept(id: "D", file: "d-seamless-loop", title: "シームレス", subtitle: "切り替えない入力を、ひと筆で。", paths: [stroke(loop, width: 2.0)])
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func bitmap(width: CGFloat, height: CGFloat, scale: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.translateBy(x: 0, y: height * CGFloat(scale))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: width, height: height)
    return rep
}

func drawIcon(_ concept: Concept, _ context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, ink: NSColor) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.scaleBy(x: size / 18, y: size / 18)
    context.setFillColor(ink.cgColor)
    for path in concept.paths { context.addPath(path); context.fillPath() }
    context.restoreGState()
}

func number(_ value: CGFloat) -> String {
    String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
}
func svgPath(_ path: CGPath) -> String {
    var instructions: [String] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        func point(_ index: Int) -> String { "\(number(element.points[index].x)) \(number(element.points[index].y))" }
        switch element.type {
        case .moveToPoint: instructions.append("M" + point(0))
        case .addLineToPoint: instructions.append("L" + point(0))
        case .addQuadCurveToPoint: instructions.append("Q" + point(0) + " " + point(1))
        case .addCurveToPoint: instructions.append("C" + point(0) + " " + point(1) + " " + point(2))
        case .closeSubpath: instructions.append("Z")
        @unknown default: fatalError("Unknown path element")
        }
    }
    return instructions.joined(separator: " ")
}

for concept in concepts {
    for path in concept.paths {
        precondition(CGRect(x: 0, y: 0, width: 18, height: 18).contains(path.boundingBoxOfPath))
    }
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 18 18\" width=\"18\" height=\"18\"><title>\(concept.id): \(concept.title)</title>"
        + concept.paths.map { "<path fill=\"currentColor\" d=\"\(svgPath($0))\"/>" }.joined() + "</svg>\n"
    try svg.write(to: destination.appendingPathComponent(concept.file + ".svg"), atomically: true, encoding: .utf8)
    var reps: [NSBitmapImageRep] = []
    for scale in [1, 2] {
        let rep = bitmap(width: 18, height: 18, scale: scale) { context in
            drawIcon(concept, context, x: 0, y: 0, size: 18, ink: .black)
        }
        let suffix = scale == 1 ? "" : "@2x"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(concept.file + suffix + ".png"))
        reps.append(rep)
    }
    try NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps)!.write(to: destination.appendingPathComponent(concept.file + ".tiff"))
}

func rectangle(_ context: CGContext, _ rect: CGRect, radius: CGFloat, fill: NSColor) {
    context.setFillColor(fill.cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func label(_ text: String, _ context: CGContext, x: CGFloat, baseline: CGFloat, size: CGFloat,
           weight: NSFont.Weight = .regular, ink: NSColor) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink
    ]))
    context.saveGState()
    context.translateBy(x: x, y: baseline)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

let ink = color(0x172322), secondary = color(0x596661), green = color(0x2D6556)
func menu(_ concept: Concept, _ context: CGContext, x: CGFloat, y: CGFloat, dark: Bool) {
    let foreground = dark ? color(0xF3F5F3) : ink
    rectangle(context, CGRect(x: x, y: y, width: 188, height: 36), radius: 8,
        fill: dark ? color(0x28332F) : color(0xE8EDE8))
    label("•••", context, x: x + 13, baseline: y + 22, size: 12, ink: foreground.withAlphaComponent(0.45))
    drawIcon(concept, context, x: x + 58, y: y + 9, size: 18, ink: foreground)
    context.setStrokeColor(foreground.cgColor)
    context.setLineWidth(1.2)
    context.addPath(CGPath(roundedRect: CGRect(x: x + 94, y: y + 13, width: 18, height: 10), cornerWidth: 2, cornerHeight: 2, transform: nil))
    context.strokePath()
    rectangle(context, CGRect(x: x + 96, y: y + 15, width: 11, height: 6), radius: 1, fill: foreground)
    context.fill(CGRect(x: x + 113, y: y + 16, width: 1.5, height: 4))
    label("9:41", context, x: x + 133, baseline: y + 23, size: 13, weight: .medium, ink: foreground)
}

let sheet = bitmap(width: 736, height: 726, scale: 2) { context in
    context.setFillColor(color(0xF5F6F1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 736, height: 726))
    label("AZOOKEY MIXED  /  MENU ICON STUDIES", context, x: 24, baseline: 30, size: 10, weight: .semibold, ink: green)
    label("小さなアイコンに、混在入力の意味を。", context, x: 24, baseline: 66, size: 24, weight: .semibold, ink: ink)
    label("4つの方向性  ·  単色  ·  18pt相当のメニューバー比較", context, x: 24, baseline: 95, size: 12, ink: secondary)
    for (index, concept) in concepts.enumerated() {
        let x = CGFloat(index % 2) * 352 + 24
        let y = CGFloat(index / 2) * 280 + 123
        rectangle(context, CGRect(x: x, y: y, width: 336, height: 260), radius: 16, fill: .white)
        label(concept.id, context, x: x + 20, baseline: y + 31, size: 12, weight: .semibold, ink: green)
        label(concept.title, context, x: x + 44, baseline: y + 32, size: 17, weight: .semibold, ink: ink)
        if index == 0 {
            rectangle(context, CGRect(x: x + 244, y: y + 14, width: 74, height: 24), radius: 12, fill: color(0xE8F0E9))
            label("おすすめ", context, x: x + 255, baseline: y + 30, size: 11, weight: .medium, ink: green)
        }
        drawIcon(concept, context, x: x + 27, y: y + 82, size: 72, ink: ink)
        label("拡大", context, x: x + 51, baseline: y + 177, size: 10, ink: secondary)
        menu(concept, context, x: x + 128, y: y + 73, dark: false)
        menu(concept, context, x: x + 128, y: y + 120, dark: true)
        label("18pt相当 / ライト・ダーク", context, x: x + 142, baseline: y + 177, size: 10, ink: secondary)
        label(concept.subtitle, context, x: x + 20, baseline: y + 213, size: 13, weight: .medium, ink: ink)
        let notes = ["混在が伝わる / 字形はやや細かい", "自動感がある / AIの印象も強め", "小さくても明快 / 初見では説明が必要", "最も軽やか / 入力モードとは伝わりにくい"]
        label(notes[index], context, x: x + 20, baseline: y + 237, size: 11, ink: secondary)
    }
    label("候補比較用。現在のIMEアイコンは変更していません。", context, x: 24, baseline: 712, size: 11, ink: secondary)
}
try sheet.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("comparison.png"))
print("Exported four icon concepts, 1x/2x PNGs, SVGs, TIFFs and comparison.png")
