#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private enum CaptureError: Error, CustomStringConvertible {
    case usage
    case operational(String)
    case contract(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: maccatalyst-capture-window.swift <pid> <window-id> <logical-width> <logical-height> <output.png> <evidence.json>"
        case let .operational(reason), let .contract(reason):
            return reason
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .contract: 65
        case .operational: 70
        }
    }
}

private func canonicalPositiveInteger(_ value: String) -> Int? {
    guard let parsed = Int(value), parsed > 0, String(parsed) == value else { return nil }
    return parsed
}

private func run() async throws {
    guard CommandLine.arguments.count == 7,
          let processID = canonicalPositiveInteger(CommandLine.arguments[1]),
          let windowID = canonicalPositiveInteger(CommandLine.arguments[2]),
          let logicalWidth = canonicalPositiveInteger(CommandLine.arguments[3]),
          let logicalHeight = canonicalPositiveInteger(CommandLine.arguments[4]),
          logicalWidth == 1_280,
          logicalHeight == 800 else {
        throw CaptureError.usage
    }
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[5])
    let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[6])
    guard outputURL.path.hasPrefix("/"), evidenceURL.path.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: outputURL.path),
          !FileManager.default.fileExists(atPath: evidenceURL.path) else {
        throw CaptureError.usage
    }
    guard CGPreflightScreenCaptureAccess() else {
        throw CaptureError.operational("Screen Recording permission is required for native window capture")
    }

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
    } catch {
        throw CaptureError.operational("could not enumerate ScreenCaptureKit windows: \(error.localizedDescription)")
    }
    let matchingWindows = content.windows.filter {
        Int($0.windowID) == windowID && Int($0.owningApplication?.processID ?? -1) == processID
    }
    guard matchingWindows.count == 1 else {
        throw CaptureError.operational("ScreenCaptureKit did not find exactly one PID/window-ID match")
    }
    let window = matchingWindows[0]
    guard window.isOnScreen,
          abs(window.frame.width - CGFloat(logicalWidth)) <= 0.25,
          abs(window.frame.height - CGFloat(logicalHeight)) <= 0.25 else {
        throw CaptureError.contract("ScreenCaptureKit window is not the ready 1280x800 logical frame")
    }

    let configuration = SCStreamConfiguration()
    configuration.width = 2_560
    configuration.height = 1_600
    configuration.captureResolution = .best
    configuration.scalesToFit = false
    configuration.preservesAspectRatio = true
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.ignoreGlobalClipSingleWindow = true
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let image: CGImage
    do {
        image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    } catch {
        throw CaptureError.operational("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
    }
    guard image.width == 2_560, image.height == 1_600 else {
        throw CaptureError.contract(
            "native ScreenCaptureKit image is \(image.width)x\(image.height), expected 2560x1600; no resize was performed"
        )
    }

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CaptureError.operational("could not create raw PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CaptureError.operational("could not encode the native ScreenCaptureKit PNG")
    }

    let evidence: [String: Any] = [
        "schemaVersion": 1,
        "captureApi": "ScreenCaptureKit.SCScreenshotManager",
        "processId": processID,
        "windowId": windowID,
        "logicalFrame": [
            "x": window.frame.minX,
            "y": window.frame.minY,
            "width": window.frame.width,
            "height": window.frame.height,
        ],
        "pixels": [2_560, 1_600],
        "captureResolution": "best",
        "scalesToFit": false,
        "postCaptureResizePerformed": false,
        "showsCursor": false,
        "ignoreShadowsSingleWindow": true,
    ]
    let evidenceData = try JSONSerialization.data(
        withJSONObject: evidence,
        options: [.prettyPrinted, .sortedKeys]
    )
    do {
        try evidenceData.write(to: evidenceURL, options: .withoutOverwriting)
    } catch {
        throw CaptureError.operational("could not write native-capture evidence: \(error.localizedDescription)")
    }
}

_ = NSApplication.shared
Task {
    do {
        try await run()
        exit(0)
    } catch let error as CaptureError {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(error.exitCode)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(70)
    }
}
dispatchMain()
