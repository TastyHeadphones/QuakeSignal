#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO

private func drawText(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor = .white) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        .foregroundColor: color,
    ]
    (value as NSString).draw(at: point, withAttributes: attributes)
}

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: ios-screenshot-content-validator-fixture.swift <iphone|ipad> <mode> <output.png>\n", stderr)
    exit(64)
}
let displayClass = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard outputURL.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: outputURL.path) else {
    fputs("error: output must be a new absolute path\n", stderr)
    exit(64)
}
let size: CGSize
switch displayClass {
case "iphone": size = CGSize(width: 1_242, height: 2_688)
case "ipad": size = CGSize(width: 2_064, height: 2_752)
default:
    fputs("error: unsupported display class\n", stderr)
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
) else { exit(70) }
context.setFillColor(red: 0.015, green: 0.015, blue: 0.02, alpha: 1)
context.fill(CGRect(origin: .zero, size: size))

if mode != "blank" {
    context.setFillColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    if mode == "sparse-reports" {
        guard displayClass == "ipad" else {
            fputs("error: sparse reports fixture requires iPad dimensions\n", stderr)
            exit(64)
        }
        // A deterministic dark plain-list composition: every non-black pixel
        // remains inside a 288-pixel band (about 10.5% of sampled rows), while
        // the right-hand stripes independently guarantee bright/edge detail.
        let band = CGRect(x: 0, y: size.height - 288, width: size.width, height: 288)
        context.fill(band)
        context.setFillColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1)
        for x in stride(from: 1_760, to: Int(size.width), by: 16) {
            context.fill(CGRect(x: CGFloat(x), y: band.minY, width: 8, height: band.height))
        }
    } else {
        for y in stride(from: 220, to: Int(size.height) - 260, by: 420) {
            context.fill(CGRect(x: 40, y: CGFloat(y), width: size.width - 80, height: 280))
        }
    }
    if mode == "map" || mode == "map-placeholder" {
        context.setFillColor(red: 0.08, green: 0.32, blue: 0.58, alpha: 1)
        context.fill(CGRect(x: 40, y: 280, width: (size.width - 100) / 2, height: size.height - 700))
        context.setFillColor(red: 0.12, green: 0.52, blue: 0.24, alpha: 1)
        context.fill(CGRect(x: 60 + (size.width - 100) / 2, y: 280, width: (size.width - 100) / 2, height: size.height - 700))
    }

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let fontSize: CGFloat = mode == "sparse-reports"
        ? 34
        : (displayClass == "iphone" ? 42 : 52)
    let lines: [String]
    switch mode {
    case "home", "permission":
        lines = ["QuakeSignal Home", "Latest Earthquake", "No nearby activity", "Noto Peninsula Ishikawa", "Magnitude 7.6", mode == "permission" ? "Allow While Using App" : "Final historical report"]
    case "reports":
        lines = ["QuakeSignal Reports", "Earthquake List", "Noto Peninsula", "Off Fukushima Prefecture", "Magnitude 7.6", "Final historical report"]
    case "sparse-reports":
        lines = ["Earthquake List", "Noto Peninsula", "Off Fukushima Prefecture", "Final Reports", "Magnitude 7.6", "JMA History"]
    case "map":
        lines = ["QuakeSignal Map", "24 hours", "7 days 30 days", "All", "M3+", "M4+", "M5+ Earthquake markers", "Maps Legal"]
    case "map-placeholder":
        lines = ["QuakeSignal Map", "24 hours", "All", "Loading map", "Maps Legal", "Please wait"]
    case "guide":
        lines = ["QuakeSignal Guide", "Available offline", "When an Earthquake Strikes", "Indoors", "Drop cover and hold on", "Preparedness guidance"]
    case "settings":
        lines = ["QuakeSignal Settings", "Alert Sound", "Japanese Safety Voice", "HTS Voice Mei", "CC BY 3.0", "Preview Selected Sound"]
    case "placeholder":
        lines = ["QuakeSignal", "Loading", "Please wait", "Preparing view", "Starting app", "Almost ready"]
    default:
        fputs("error: unsupported fixture mode\n", stderr)
        exit(64)
    }
    for (index, line) in lines.enumerated() {
        let y = mode == "sparse-reports"
            ? size.height - 48 - CGFloat(index) * 44
            : size.height - 260 - CGFloat(index) * 300
        drawText(
            line,
            at: CGPoint(x: 70, y: y),
            size: fontSize,
            color: index == 0 ? .white : .lightGray
        )
    }
    NSGraphicsContext.restoreGraphicsState()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    exit(70)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(70) }
