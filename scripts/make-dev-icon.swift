#!/usr/bin/env swift
//
// Bake a "DEV" corner ribbon onto every Release icon and emit a parallel
// AppIcon-Dev.appiconset. Run once whenever the source AppIcon changes.
//
//   swift scripts/make-dev-icon.swift
//

import AppKit
import Foundation

let fm = FileManager.default
let here = URL(fileURLWithPath: fm.currentDirectoryPath)
let src = here.appendingPathComponent("Glint/Resources/Assets.xcassets/AppIcon.appiconset")
let dst = here.appendingPathComponent("Glint/Resources/Assets.xcassets/AppIcon-Dev.appiconset")

guard fm.fileExists(atPath: src.path) else {
    FileHandle.standardError.write(Data("Missing \(src.path)\n".utf8))
    exit(1)
}

// Recreate dest so stale sizes don't linger.
try? fm.removeItem(at: dst)
try fm.createDirectory(at: dst, withIntermediateDirectories: true)

func badge(on cgImage: CGImage, size: Int) -> CGImage? {
    let w = cgImage.width, h = cgImage.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Round red badge tucked into the bottom-right corner. Geometry
    // scales with the icon so 16/32 px still get a recognizable red dot.
    let W = CGFloat(w)
    let radius = W * 0.11
    let padding = W * 0.07
    let center = CGPoint(x: W - radius - padding, y: radius + padding)

    // White halo ring so the badge reads on any backdrop.
    ctx.saveGState()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - radius - max(1, W * 0.012),
                               y: center.y - radius - max(1, W * 0.012),
                               width: 2 * (radius + max(1, W * 0.012)),
                               height: 2 * (radius + max(1, W * 0.012))))

    ctx.setFillColor(NSColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                               width: 2 * radius, height: 2 * radius))

    // "DEV" centered in the badge. Drop the label on tiny sizes where
    // it would just be smudge — the red dot alone is enough signal.
    if size >= 64 {
        let fontSize = radius * 0.7
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.05,
        ]
        let text = NSAttributedString(string: "DEV", attributes: attrs)
        // NSAttributedString assumes a flipped (top-down) coordinate
        // system — let NSGraphicsContext flip the CGContext for us so
        // the glyphs render right-side up.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let s = text.size()
        // CG origin is bottom-left, but with the flip above we draw in
        // top-down space. Translate the center into that space.
        let flippedY = CGFloat(h) - center.y
        text.draw(at: CGPoint(x: center.x - s.width / 2, y: flippedY - s.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    ctx.restoreGState()
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-dev-icon", code: 1)
    }
    try data.write(to: url)
}

let pngs = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }

for url in pngs {
    guard let nsImage = NSImage(contentsOf: url),
          let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write(Data("Skipping unreadable \(url.lastPathComponent)\n".utf8))
        continue
    }
    guard let stamped = badge(on: cg, size: cg.width) else { continue }
    let out = dst.appendingPathComponent(url.lastPathComponent)
    try writePNG(stamped, to: out)
    print("✓ \(url.lastPathComponent) — \(cg.width)px")
}

// Mirror the Contents.json verbatim so xcassets compiler is happy.
let contents = src.appendingPathComponent("Contents.json")
try fm.copyItem(at: contents, to: dst.appendingPathComponent("Contents.json"))

print("→ \(dst.path)")
