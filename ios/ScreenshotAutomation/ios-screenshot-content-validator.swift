#!/usr/bin/swift

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

private enum ValidationError: Error, CustomStringConvertible {
    case usage
    case operational(String)
    case semantic([String])

    var description: String {
        switch self {
        case .usage:
            return "Usage: ios-screenshot-content-validator.swift <selector> <absolute-png-or-jpeg> <absolute-evidence.json>"
        case let .operational(reason):
            return reason
        case let .semantic(reasons):
            return reasons.joined(separator: "; ")
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .semantic: 65
        case .operational: 70
        }
    }
}

private struct SelectorContract {
    let pixels: [Int]
    let requiredTermGroups: [[String]]
    let requiresChromaticMap: Bool
}

private struct PixelMetrics {
    let luminanceStandardDeviation: Double
    let nonBlackFraction: Double
    let brightFraction: Double
    let chromaticFraction: Double
    let horizontalEdgeFraction: Double
    let sampledPixels: Int
}

private let routes: [(suffix: String, groups: [[String]], map: Bool)] = [
    ("home", [["latest earthquake"], ["no nearby activity"], ["noto peninsula", "ishikawa"]], false),
    ("reports", [["earthquake list"], ["noto peninsula"], ["fukushima"]], false),
    // The current map renders these chip labels as pixels. Annotation titles
    // and accessibility-only filter labels are deliberately not OCR gates.
    ("map", [["map"], ["24 hours"], ["all"], ["m3+", "m3"], ["m4+", "m4"]], true),
    ("guide", [["available offline"], ["when an earthquake strikes"], ["indoors", "outdoors"]], false),
    ("alert-preferences", [["alert sound"], ["japanese safety voice"], ["cc by 3.0"]], false),
]

private let selectorContracts: [String: SelectorContract] = {
    var contracts: [String: SelectorContract] = [:]
    for (prefix, pixels) in [
        ("ios-iphone-6.5", [1_242, 2_688]),
        ("ios-ipad-13", [2_064, 2_752]),
    ] {
        for route in routes {
            contracts["\(prefix)-\(route.suffix)"] = SelectorContract(
                pixels: pixels,
                requiredTermGroups: route.groups,
                requiresChromaticMap: route.map
            )
        }
    }
    return contracts
}()

private let forbiddenSystemPromptGroups = [
    ["would like to send you notifications"],
    ["allow while using app", "allow while using the app"],
    ["allow once"],
    ["don t allow"],
]

private func loadImage(_ data: Data, expectedPixels: [Int]) throws -> (CGImage, String) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ValidationError.operational("could not decode exactly one screenshot image")
    }
    let actual = [image.width, image.height]
    guard actual == expectedPixels else {
        throw ValidationError.semantic([
            "image is \(image.width)x\(image.height), expected \(expectedPixels[0])x\(expectedPixels[1])",
        ])
    }
    guard let type = CGImageSourceGetType(source) as String? else {
        throw ValidationError.operational("could not determine screenshot image format")
    }
    return (image, type == "public.jpeg" ? "jpeg" : type == "public.png" ? "png" : type)
}

private func pixelMetrics(_ image: CGImage) throws -> PixelMetrics {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ValidationError.operational("could not allocate semantic-validation pixel context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let sampleStride = 8
    var count = 0
    var luminanceSum = 0.0
    var luminanceSquaredSum = 0.0
    var nonBlack = 0
    var bright = 0
    var chromatic = 0
    var edges = 0
    var edgeComparisons = 0
    for y in Swift.stride(from: 0, to: height, by: sampleStride) {
        var previousLuminance: Double?
        for x in Swift.stride(from: 0, to: width, by: sampleStride) {
            let offset = y * bytesPerRow + x * 4
            let red = Double(bytes[offset])
            let green = Double(bytes[offset + 1])
            let blue = Double(bytes[offset + 2])
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            luminanceSum += luminance
            luminanceSquaredSum += luminance * luminance
            count += 1
            if max(red, green, blue) > 18 { nonBlack += 1 }
            if luminance > 120 { bright += 1 }
            if max(red, green, blue) - min(red, green, blue) > 24 { chromatic += 1 }
            if let previousLuminance {
                edgeComparisons += 1
                if abs(luminance - previousLuminance) > 26 { edges += 1 }
            }
            previousLuminance = luminance
        }
    }
    guard count > 0, edgeComparisons > 0 else {
        throw ValidationError.operational("semantic pixel sampler produced no observations")
    }
    let mean = luminanceSum / Double(count)
    let variance = max(0, luminanceSquaredSum / Double(count) - mean * mean)
    return PixelMetrics(
        luminanceStandardDeviation: sqrt(variance),
        nonBlackFraction: Double(nonBlack) / Double(count),
        brightFraction: Double(bright) / Double(count),
        chromaticFraction: Double(chromatic) / Double(count),
        horizontalEdgeFraction: Double(edges) / Double(edgeComparisons),
        sampledPixels: count
    )
}

private func recognizedText(_ imageData: Data) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(data: imageData)
    do {
        try handler.perform([request])
    } catch {
        throw ValidationError.operational("Vision text recognition failed: \(error.localizedDescription)")
    }
    guard let observations = request.results else {
        throw ValidationError.operational("Vision returned no text-recognition result set")
    }
    return observations.compactMap { $0.topCandidates(1).first?.string }
}

private func normalized(_ value: String) -> String {
    value.lowercased().replacingOccurrences(
        of: "[^a-z0-9+.]+",
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func writeEvidence(
    to url: URL,
    selector: String,
    status: String,
    reasons: [String],
    contract: SelectorContract,
    metrics: PixelMetrics,
    text: [String],
    matchedGroups: [[String]],
    forbiddenMatches: [[String]],
    imageSha256: String,
    imageFormat: String
) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationError.operational("refusing to overwrite semantic evidence")
    }
    let record: [String: Any] = [
        "schemaVersion": 1,
        "status": status,
        "captureSelector": selector,
        "imageSha256": imageSha256,
        "imageFormat": imageFormat,
        "pixels": contract.pixels,
        "reasons": reasons,
        "checks": [
            "committedView": [
                "luminanceStandardDeviation": metrics.luminanceStandardDeviation,
                "nonBlackFraction": metrics.nonBlackFraction,
                "brightFraction": metrics.brightFraction,
                "chromaticFraction": metrics.chromaticFraction,
                "horizontalEdgeFraction": metrics.horizontalEdgeFraction,
                "sampledPixels": metrics.sampledPixels,
            ],
            "recognizedText": text,
            "matchedRequiredTermGroups": matchedGroups,
            "matchedForbiddenSystemPromptGroups": forbiddenMatches,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    do {
        try data.write(to: url, options: .withoutOverwriting)
    } catch {
        throw ValidationError.operational("could not write semantic evidence: \(error.localizedDescription)")
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 4 else { throw ValidationError.usage }
    let selector = CommandLine.arguments[1]
    guard let contract = selectorContracts[selector] else { throw ValidationError.usage }
    let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[3])
    guard imageURL.path.hasPrefix("/"), evidenceURL.path.hasPrefix("/") else {
        throw ValidationError.usage
    }

    let imageData: Data
    do {
        imageData = try Data(contentsOf: imageURL)
    } catch {
        throw ValidationError.operational("could not snapshot screenshot image: \(error.localizedDescription)")
    }
    let (image, imageFormat) = try loadImage(imageData, expectedPixels: contract.pixels)
    let imageSha256 = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    let metrics = try pixelMetrics(image)
    let text = try recognizedText(imageData)
    let searchableText = normalized(text.joined(separator: " "))
    let matchedGroups = contract.requiredTermGroups.filter { alternatives in
        alternatives.contains { searchableText.contains(normalized($0)) }
    }
    let forbiddenMatches = forbiddenSystemPromptGroups.filter { alternatives in
        alternatives.contains { searchableText.contains(normalized($0)) }
    }

    var reasons: [String] = []
    if metrics.luminanceStandardDeviation < 12 { reasons.append("committed-view luminance variation is too low") }
    if metrics.nonBlackFraction < 0.12 { reasons.append("committed-view non-black coverage is too low") }
    if metrics.brightFraction < 0.004 { reasons.append("committed-view bright-detail coverage is too low") }
    if metrics.horizontalEdgeFraction < 0.004 { reasons.append("committed-view edge detail is too low") }
    if text.count < 5 { reasons.append("committed-view recognized text inventory is too small") }
    if matchedGroups.count != contract.requiredTermGroups.count {
        reasons.append("requested route terms are missing")
    }
    if !forbiddenMatches.isEmpty { reasons.append("a system permission dialog is visible") }
    if contract.requiresChromaticMap && metrics.chromaticFraction < 0.02 {
        reasons.append("map chromatic content is too low")
    }

    let status = reasons.isEmpty ? "accepted" : "rejected"
    try writeEvidence(
        to: evidenceURL,
        selector: selector,
        status: status,
        reasons: reasons,
        contract: contract,
        metrics: metrics,
        text: text,
        matchedGroups: matchedGroups,
        forbiddenMatches: forbiddenMatches,
        imageSha256: imageSha256,
        imageFormat: imageFormat
    )
    if !reasons.isEmpty { throw ValidationError.semantic(reasons) }
}

do {
    try run()
} catch let error as ValidationError {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(70)
}
