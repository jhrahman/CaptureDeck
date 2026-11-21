import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

/// Draws the README pictures from the real editor, on made-up data. Only runs when README_SHOTS_DIR is set.
@MainActor
struct ReadmeShots {
    static var outputDir: String? { ProcessInfo.processInfo.environment["README_SHOTS_DIR"] }

    // MARK: A made-up web app to annotate (nothing real on it)

    private static func color(_ hex: String) -> NSColor {
        let c = RGBAColor(hex: hex) ?? .black
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// Top-left origin, so these coordinates match the annotation coordinates.
    private static func canvas(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CapturedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }

    private static func card(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: CGColor(gray: 0, alpha: 0.10))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
    }

    static func dashboard() -> CapturedImage {
        canvas(1360, 820) { ctx in
            ctx.setFillColor(color("#F3F5F9").cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1360, height: 820))
            // sidebar
            ctx.setFillColor(color("#111827").cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 220, height: 820))
            text("Northwind", at: CGPoint(x: 28, y: 28), size: 20, weight: .bold, color: .white)
            for (i, item) in ["Overview", "Revenue", "Customers", "Reports", "Settings"].enumerated() {
                if i == 1 { ctx.setFillColor(color("#2563EB").cgColor); ctx.addPath(CGPath(roundedRect: CGRect(x: 14, y: 96 + CGFloat(i) * 46, width: 192, height: 38), cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath() }
                text(item, at: CGPoint(x: 34, y: 105 + CGFloat(i) * 46), size: 15, weight: .medium, color: i == 1 ? .white : color("#9CA3AF"))
            }
            // header
            text("Revenue", at: CGPoint(x: 260, y: 36), size: 30, weight: .bold, color: color("#111827"))
            text("Last 30 days", at: CGPoint(x: 262, y: 78), size: 15, color: color("#6B7280"))
            // stat cards
            let stats = [("Total revenue", "$48,290", "+12.4%", "#16A34A"), ("Orders", "1,284", "+3.1%", "#16A34A"), ("Refunds", "$1,920", "+38%", "#DC2626")]
            for (i, s) in stats.enumerated() {
                let r = CGRect(x: 260 + CGFloat(i) * 364, y: 124, width: 340, height: 120)
                card(ctx, r)
                text(s.0, at: CGPoint(x: r.minX + 24, y: r.minY + 20), size: 14, color: color("#6B7280"))
                text(s.1, at: CGPoint(x: r.minX + 24, y: r.minY + 46), size: 36, weight: .bold, color: color("#111827"))
                text(s.2, at: CGPoint(x: r.minX + 24, y: r.minY + 92), size: 14, weight: .semibold, color: color(s.3))
            }
            // chart
            let chart = CGRect(x: 260, y: 272, width: 704, height: 500)
            card(ctx, chart)
            text("Daily revenue", at: CGPoint(x: chart.minX + 28, y: chart.minY + 24), size: 17, weight: .semibold, color: color("#111827"))
            let pts: [CGFloat] = [0.40, 0.46, 0.44, 0.52, 0.58, 0.55, 0.63, 0.70, 0.66, 0.74, 0.30, 0.38, 0.52, 0.61, 0.68, 0.72, 0.79, 0.76, 0.84, 0.88]
            let plot = CGRect(x: chart.minX + 36, y: chart.minY + 80, width: chart.width - 72, height: chart.height - 130)
            ctx.setStrokeColor(color("#E5E7EB").cgColor); ctx.setLineWidth(1)
            for g in 0...4 { let y = plot.minY + plot.height * CGFloat(g) / 4; ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y)); ctx.strokePath() }
            let line = CGMutablePath()
            for (i, v) in pts.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(pts.count - 1), y: plot.maxY - plot.height * v)
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); area.closeSubpath()
            ctx.setFillColor(color("#2563EB").withAlphaComponent(0.10).cgColor); ctx.addPath(area); ctx.fillPath()
            ctx.setStrokeColor(color("#2563EB").cgColor); ctx.setLineWidth(3.5); ctx.setLineJoin(.round); ctx.addPath(line); ctx.strokePath()
            // team card
            let team = CGRect(x: 988, y: 272, width: 336, height: 500)
            card(ctx, team)
            text("Top customers", at: CGPoint(x: team.minX + 24, y: team.minY + 24), size: 17, weight: .semibold, color: color("#111827"))
            let rows = [("Acme Labs", "$9,420"), ("Globex", "$7,880"), ("Initech", "$6,310"), ("Umbrella", "$5,095"), ("Hooli", "$4,760")]
            for (i, r) in rows.enumerated() {
                let y = team.minY + 84 + CGFloat(i) * 64
                ctx.setFillColor(color(["#DBEAFE", "#DCFCE7", "#FEF3C7", "#FCE7F3", "#EDE9FE"][i]).cgColor)
                ctx.fillEllipse(in: CGRect(x: team.minX + 24, y: y, width: 40, height: 40))
                text(r.0, at: CGPoint(x: team.minX + 78, y: y + 10), size: 15, weight: .medium, color: color("#111827"))
                text(r.1, at: CGPoint(x: team.maxX - 92, y: y + 10), size: 15, weight: .semibold, color: color("#374151"))
            }
        }
    }

    static func settingsPage() -> CapturedImage {
        canvas(1240, 700) { ctx in
            ctx.setFillColor(color("#F3F5F9").cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1240, height: 700))
            text("Developer settings", at: CGPoint(x: 60, y: 44), size: 30, weight: .bold, color: color("#111827"))
            text("Keys and contact details for this workspace", at: CGPoint(x: 62, y: 88), size: 15, color: color("#6B7280"))
            let panel = CGRect(x: 60, y: 140, width: 1120, height: 500)
            card(ctx, panel)
            let fields = [("Account email", "maya.lindqvist@northwind.example"), ("Production API key", "nw_live_8fK2mQ9xTz41LcVb7sRaYp03"),
                          ("Webhook secret", "whsec_4Jd9Pq27XnT0cVuB6eMk"), ("Billing phone", "+1 (415) 555-0137")]
            for (i, f) in fields.enumerated() {
                let y = panel.minY + 40 + CGFloat(i) * 110
                text(f.0, at: CGPoint(x: panel.minX + 40, y: y), size: 14, weight: .medium, color: color("#6B7280"))
                ctx.setFillColor(color("#F9FAFB").cgColor); ctx.setStrokeColor(color("#D1D5DB").cgColor); ctx.setLineWidth(1.5)
                let box = CGRect(x: panel.minX + 40, y: y + 28, width: 760, height: 50)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.drawPath(using: .fillStroke)
                text(f.1, at: CGPoint(x: box.minX + 18, y: box.minY + 13), size: 20, weight: .regular, color: color("#111827"), mono: true)
            }
        }
    }

    // MARK: Rendering

    private static func shoot(_ doc: EditorDocument, width: CGFloat, height: CGFloat, name: String, prepare: (EditorViewController) -> Void = { _ in }) throws {
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        prepare(controller)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try UXSnapshotTests.render(controller, width: width, height: height, dark: true, name: name)
    }

    private func add(_ doc: EditorDocument, _ tool: EditorToolDescriptor, _ shape: any AnnotationShape, tweak: (inout AnnotationStyle) -> Void = { _ in }) {
        var style = tool.defaultStyle
        tweak(&style)
        doc.addAnnotation(Annotation(shape: shape, style: style), select: false)
    }

    @Test func annotateShot() throws {
        guard let dir = Self.outputDir else { return }
        setenv("UX_PNG_DIR", dir, 1)
        let doc = EditorDocument(original: Self.dashboard(), title: "revenue")
        doc.startsWithFullSelection = false
        let red = RGBAColor(hex: "#FF3B30FF")!
        // flag the refunds spike, then point at the dip in the chart
        add(doc, EditorToolRegistry.highlighter, HighlighterShape(rect: CGRect(x: 1008, y: 170, width: 124, height: 46)))
        add(doc, EditorToolRegistry.rectangle, RectangleShape(rect: CGRect(x: 982, y: 128, width: 336, height: 112))) { $0.strokeColor = red; $0.lineWidth = 5; $0.cornerRadius = 14 }
        add(doc, EditorToolRegistry.arrow, LineShape(start: CGPoint(x: 560, y: 690), end: CGPoint(x: 606, y: 590))) { $0.strokeColor = red; $0.lineWidth = 6; $0.endHead = .filled }
        add(doc, EditorToolRegistry.callout, CalloutShape(rect: CGRect(x: 330, y: 680, width: 340, height: 124), text: "Dip right after the April 12 deploy", tip: CGPoint(x: 560, y: 700)))
        add(doc, EditorToolRegistry.step, StepShape(center: CGPoint(x: 982, y: 128), radius: 20, number: 1))
        add(doc, EditorToolRegistry.step, StepShape(center: CGPoint(x: 606, y: 574), radius: 20, number: 2))
        doc.clearAnnotationSelection()
        try Self.shoot(doc, width: 940, height: 600, name: "annotate") { $0.selectTool(id: EditorToolRegistry.pointer.id) }
    }

    @Test func hideShot() throws {
        guard let dir = Self.outputDir else { return }
        setenv("UX_PNG_DIR", dir, 1)
        let doc = EditorDocument(original: Self.settingsPage(), title: "keys")
        doc.startsWithFullSelection = false
        // email: blur, API key: solid, webhook secret: pixelate; the phone number stays visible on purpose
        add(doc, EditorToolRegistry.redactBrush, RedactBrushShape(points: [CGPoint(x: 128, y: 233), CGPoint(x: 500, y: 233)])) { $0.redaction = .blur; $0.lineWidth = 38; $0.strength = 14 }
        add(doc, EditorToolRegistry.redactBrush, RedactBrushShape(points: [CGPoint(x: 128, y: 343), CGPoint(x: 500, y: 343)])) { $0.redaction = .solid; $0.lineWidth = 38; $0.strokeColor = RGBAColor(hex: "#111827FF")! }
        add(doc, EditorToolRegistry.redactBrush, RedactBrushShape(points: [CGPoint(x: 128, y: 453), CGPoint(x: 420, y: 453)])) { $0.redaction = .pixelate; $0.lineWidth = 38; $0.strength = 12 }
        add(doc, EditorToolRegistry.callout, CalloutShape(rect: CGRect(x: 900, y: 300, width: 250, height: 84), text: "Hidden before I share it", tip: CGPoint(x: 700, y: 343)))
        doc.clearAnnotationSelection()
        try Self.shoot(doc, width: 940, height: 560, name: "hide") { $0.selectTool(id: EditorToolRegistry.redactBrush.id) }
    }
}
