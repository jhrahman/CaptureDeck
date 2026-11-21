import AppKit
import CoreModels
import Foundation
import Testing
@testable import CaptureEngine

/// Draws the multi display README picture from made-up desktops. Only runs when README_SHOTS_DIR is set.
struct ReadmeDisplayShot {
    private func desktop(_ w: Int, _ h: Int, top: [CGFloat], bottom: [CGFloat], windows: [(CGRect, [CGFloat])]) -> CapturedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: top[0], green: top[1], blue: top[2], alpha: 1), CGColor(red: bottom[0], green: bottom[1], blue: bottom[2], alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        for (frame, rgb) in windows {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1))
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
            ctx.restoreGState()
            // title bar dots and a few content lines
            for (i, c) in [[1, 0.37, 0.34], [1, 0.74, 0.18], [0.16, 0.8, 0.25]].enumerated() {
                ctx.setFillColor(CGColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1))
                ctx.fillEllipse(in: CGRect(x: frame.minX + 24 + CGFloat(i) * 28, y: frame.maxY - 40, width: 14, height: 14))
            }
            ctx.setFillColor(CGColor(gray: rgb[0] > 0.5 ? 0.0 : 1.0, alpha: 0.12))
            for line in 0..<7 {
                let width = frame.width * (0.35 + 0.5 * CGFloat((line * 37) % 10) / 10)
                ctx.addPath(CGPath(roundedRect: CGRect(x: frame.minX + 36, y: frame.maxY - 100 - CGFloat(line) * 44, width: width, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
            }
        }
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
    }

    @Test func displaysShot() throws {
        guard let dir = ProcessInfo.processInfo.environment["README_SHOTS_DIR"] else { return }
        let main = desktop(2880, 1800, top: [0.36, 0.30, 0.78], bottom: [0.93, 0.45, 0.58], windows: [
            (CGRect(x: 220, y: 260, width: 1500, height: 1050), [0.97, 0.97, 0.99]),
            (CGRect(x: 1250, y: 500, width: 1300, height: 900), [0.12, 0.13, 0.17]),
        ])
        let side = desktop(2560, 1440, top: [0.08, 0.16, 0.30], bottom: [0.12, 0.50, 0.55], windows: [
            (CGRect(x: 200, y: 200, width: 1900, height: 1000), [0.12, 0.13, 0.17]),
        ])
        let pieces = [
            DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), image: main),
            DisplayComposer.Piece(bounds: CGRect(x: 1440, y: 0, width: 1280, height: 720), image: side),
        ]
        let out = try #require(DisplayComposer.compose(pieces, labelled: true))
        let rep = NSBitmapImageRep(cgImage: out.cgImage)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("displays.png"))
    }
}
