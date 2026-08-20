#!/usr/bin/swift

import CoreGraphics
import Foundation
import ImageIO

private enum FlattenError: Error, CustomStringConvertible {
    case invalidArguments
    case outputExists
    case unreadableInput
    case wrongDimensions(Int, Int)
    case unsupportedImage
    case contextCreation
    case destinationCreation
    case writeFailure
    case alphaRemained

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: maccatalyst-flatten-png.swift <absolute-input.png> <absolute-output.png> <width> <height>"
        case .outputExists:
            return "refusing to overwrite the flatten output"
        case .unreadableInput:
            return "the raw PNG could not be read as exactly one image"
        case let .wrongDimensions(width, height):
            return "raw PNG is \(width)x\(height); no resize is permitted"
        case .unsupportedImage:
            return "the raw PNG has unsupported color or component metadata"
        case .contextCreation:
            return "could not create an opaque RGB bitmap context"
        case .destinationCreation:
            return "could not create the final PNG destination"
        case .writeFailure:
            return "could not finalize the final PNG"
        case .alphaRemained:
            return "the composited final PNG still contains alpha"
        }
    }
}

private func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
        return true
    case .none, .noneSkipLast, .noneSkipFirst:
        return false
    @unknown default:
        return true
    }
}

private func loadSingleImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw FlattenError.unreadableInput
    }
    return image
}

private func run() throws {
    guard CommandLine.arguments.count == 5,
          let expectedWidth = Int(CommandLine.arguments[3]),
          let expectedHeight = Int(CommandLine.arguments[4]),
          expectedWidth > 0,
          expectedHeight > 0 else {
        throw FlattenError.invalidArguments
    }

    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard inputURL.path.hasPrefix("/"), outputURL.path.hasPrefix("/") else {
        throw FlattenError.invalidArguments
    }
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw FlattenError.outputExists
    }

    let sourceImage = try loadSingleImage(inputURL)
    guard sourceImage.width == expectedWidth, sourceImage.height == expectedHeight else {
        throw FlattenError.wrongDimensions(sourceImage.width, sourceImage.height)
    }
    guard sourceImage.bitsPerComponent == 8,
          let colorSpace = sourceImage.colorSpace,
          colorSpace.model == .rgb else {
        throw FlattenError.unsupportedImage
    }

    guard let context = CGContext(
        data: nil,
        width: expectedWidth,
        height: expectedHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw FlattenError.contextCreation
    }

    let bounds = CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight)
    context.setBlendMode(.copy)
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(bounds)
    context.setBlendMode(.normal)
    context.interpolationQuality = .none
    context.draw(sourceImage, in: bounds)

    guard let opaqueImage = context.makeImage(), !hasAlpha(opaqueImage) else {
        throw FlattenError.alphaRemained
    }
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw FlattenError.destinationCreation
    }
    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FlattenError.writeFailure
    }

    let finalImage = try loadSingleImage(outputURL)
    guard finalImage.width == expectedWidth,
          finalImage.height == expectedHeight,
          !hasAlpha(finalImage) else {
        throw FlattenError.alphaRemained
    }

    let result: [String: Any] = [
        "operation": "alpha-composite",
        "backgroundRGBA": [0, 0, 0, 255],
        "resizePerformed": false,
        "rawHasAlpha": hasAlpha(sourceImage),
        "finalHasAlpha": false,
        "pixels": [expectedWidth, expectedHeight],
        "encoder": "CoreGraphics-ImageIO-PNG",
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(65)
}
