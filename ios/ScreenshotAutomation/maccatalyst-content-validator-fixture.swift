#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO

private let size = CGSize(width: 2_560, height: 1_600)

private func drawText(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor = .white) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        .foregroundColor: color,
    ]
    (value as NSString).draw(at: point, withAttributes: attributes)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: maccatalyst-content-validator-fixture.swift <mode> <output.png>\n", stderr)
    exit(64)
}
let mode = CommandLine.arguments[1]
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard outputURL.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: outputURL.path) else {
    fputs("error: output must be a new absolute path\n", stderr)
    exit(64)
}

guard let context = CGContext(
    data: nil,
    width: Int(size.width),
    height: Int(size.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    exit(70)
}
context.setFillColor(red: 0.015, green: 0.015, blue: 0.02, alpha: 1)
context.fill(CGRect(origin: .zero, size: size))

if mode != "blank" {
    context.setFillColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    for y in stride(from: 120, through: 1_280, by: 260) {
        context.fill(CGRect(x: 40, y: y, width: 2_480, height: 190))
    }
    if mode == "map-placeholder" || mode == "map" {
        context.setFillColor(red: 0.08, green: 0.32, blue: 0.58, alpha: 1)
        context.fill(CGRect(x: 40, y: 120, width: 1_180, height: 1_100))
        context.setFillColor(red: 0.12, green: 0.52, blue: 0.24, alpha: 1)
        context.fill(CGRect(x: 1_260, y: 120, width: 1_260, height: 1_100))
    }

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    drawText("QuakeSignal   Home   List   Map   Guide   Settings", at: CGPoint(x: 70, y: 1_475), size: 42)
    drawText("Final historical report", at: CGPoint(x: 100, y: 1_365), size: 36, color: .lightGray)
    drawText("JMA information relayed through Wolfx", at: CGPoint(x: 100, y: 70), size: 34, color: .lightGray)
    drawText("Always follow official announcements", at: CGPoint(x: 1_400, y: 70), size: 34, color: .lightGray)
    switch mode {
    case "placeholder":
        drawText("Loading QuakeSignal", at: CGPoint(x: 760, y: 800), size: 72)
    case "home", "permission":
        drawText("No nearby activity", at: CGPoint(x: 100, y: 1_180), size: 60)
        drawText("LATEST EARTHQUAKE", at: CGPoint(x: 100, y: 900), size: 54)
        drawText("Noto Peninsula Ishikawa Magnitude 7.6 View Details", at: CGPoint(x: 100, y: 650), size: 48)
        if mode == "permission" {
            drawText("QuakeSignal Would Like to Send You Notifications", at: CGPoint(x: 100, y: 410), size: 44)
            drawText("Don’t Allow   Allow", at: CGPoint(x: 100, y: 300), size: 40)
        }
    case "reports":
        drawText("Earthquake List", at: CGPoint(x: 100, y: 1_180), size: 64)
        drawText("Noto Peninsula Ishikawa", at: CGPoint(x: 100, y: 900), size: 52)
        drawText("Off Fukushima Prefecture", at: CGPoint(x: 100, y: 650), size: 52)
    case "map", "map-placeholder":
        drawText("Map   24 hours   7 days   30 days", at: CGPoint(x: 100, y: 1_180), size: 58)
        drawText("Maps   Legal", at: CGPoint(x: 100, y: 300), size: 48)
        if mode == "map" {
            drawText("Noto Peninsula   Ishikawa", at: CGPoint(x: 1_300, y: 760), size: 56)
        }
    case "guide":
        drawText("Guide   Available offline", at: CGPoint(x: 100, y: 1_180), size: 58)
        drawText("When an Earthquake Strikes", at: CGPoint(x: 100, y: 900), size: 52)
        drawText("After the Shaking Stops", at: CGPoint(x: 100, y: 650), size: 52)
        drawText("Emergency Kit", at: CGPoint(x: 100, y: 400), size: 52)
    case "settings":
        drawText("Alert Sound", at: CGPoint(x: 100, y: 1_180), size: 64)
        drawText("Japanese Safety Voice", at: CGPoint(x: 100, y: 900), size: 54)
        drawText("HTS Voice Mei   CC BY 3.0", at: CGPoint(x: 100, y: 650), size: 50)
    default:
        fputs("error: unsupported fixture mode\n", stderr)
        exit(64)
    }
    NSGraphicsContext.restoreGraphicsState()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    exit(70)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(70) }
