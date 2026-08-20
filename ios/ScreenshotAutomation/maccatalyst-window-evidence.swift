#!/usr/bin/swift

import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum WindowEvidenceError: Error, CustomStringConvertible {
    case invalidArguments
    case processMismatch(String)
    case timeout

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: maccatalyst-window-evidence.swift <pid> <bundle-id> <capture-selector> <geometry-evidence.json> <timeout-seconds>"
        case let .processMismatch(reason):
            return "launched process validation failed: \(reason)"
        case .timeout:
            return "timed out waiting for one ready 1280x800-point Catalyst window"
        }
    }
}

private let reviewedSelectors: Set<String> = [
    "maccatalyst-home",
    "maccatalyst-reports",
    "maccatalyst-map",
    "maccatalyst-guide",
    "maccatalyst-alert-preferences",
]

private struct WindowRecord {
    let id: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
    let frame: CGRect
}

private func number(_ dictionary: [String: Any], key: CFString) -> NSNumber? {
    dictionary[key as String] as? NSNumber
}

private func string(_ dictionary: [String: Any], key: CFString) -> String? {
    dictionary[key as String] as? String
}

private func matchingWindows(processID: pid_t) -> [WindowRecord] {
    guard let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    return windowInfo.compactMap { dictionary in
        guard number(dictionary, key: kCGWindowOwnerPID)?.int32Value == processID,
              number(dictionary, key: kCGWindowLayer)?.intValue == 0,
              number(dictionary, key: kCGWindowIsOnscreen)?.boolValue == true,
              let identifier = number(dictionary, key: kCGWindowNumber)?.uint32Value,
              let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? NSNumber,
              let y = bounds["Y"] as? NSNumber,
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber else {
            return nil
        }

        let frame = CGRect(
            x: x.doubleValue,
            y: y.doubleValue,
            width: width.doubleValue,
            height: height.doubleValue
        )
        guard abs(frame.width - 1_280) <= 0.25,
              abs(frame.height - 800) <= 0.25 else {
            return nil
        }

        return WindowRecord(
            id: identifier,
            ownerPID: processID,
            ownerName: string(dictionary, key: kCGWindowOwnerName) ?? "",
            title: string(dictionary, key: kCGWindowName),
            frame: frame
        )
    }
}

private func processExists(_ processID: pid_t) -> Bool {
    kill(processID, 0) == 0 || errno == EPERM
}

private func validateGeometryEvidence(
    at url: URL,
    processID: pid_t,
    captureSelector: String
) throws {
    guard url.path.hasPrefix("/"),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let data = try? Data(contentsOf: url),
          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WindowEvidenceError.processMismatch("geometry evidence is missing, indirect, or invalid")
    }
    let expectedKeys: Set<String> = [
        "backingScale", "captureSelector", "logicalFrame", "processId",
        "reason", "recordedAtUtc", "schemaVersion", "status",
    ]
    guard Set(record.keys) == expectedKeys,
          (record["schemaVersion"] as? NSNumber)?.intValue == 1,
          record["status"] as? String == "ready",
          record["reason"] is NSNull,
          (record["processId"] as? NSNumber)?.int32Value == processID,
          record["captureSelector"] as? String == captureSelector,
          (record["backingScale"] as? NSNumber)?.doubleValue == 2,
          let frame = record["logicalFrame"] as? [String: Any],
          Set(frame.keys) == Set(["x", "y", "width", "height"]),
          let width = (frame["width"] as? NSNumber)?.doubleValue,
          let height = (frame["height"] as? NSNumber)?.doubleValue,
          abs(width - 1_280) <= 0.25,
          abs(height - 800) <= 0.25 else {
        throw WindowEvidenceError.processMismatch(
            "geometry evidence does not bind the exact PID, selector, 1280x800 frame, and 2x scale"
        )
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 6,
          let processID = pid_t(CommandLine.arguments[1]),
          processID > 1,
          reviewedSelectors.contains(CommandLine.arguments[3]),
          let timeout = Double(CommandLine.arguments[5]),
          timeout > 0,
          timeout <= 60 else {
        throw WindowEvidenceError.invalidArguments
    }

    let expectedBundleIdentifier = CommandLine.arguments[2]
    let captureSelector = CommandLine.arguments[3]
    let geometryEvidenceURL = URL(fileURLWithPath: CommandLine.arguments[4])

    guard let runningApplication = NSRunningApplication(processIdentifier: processID) else {
        throw WindowEvidenceError.processMismatch("PID \(processID) is not an NSRunningApplication")
    }
    guard runningApplication.bundleIdentifier == expectedBundleIdentifier else {
        throw WindowEvidenceError.processMismatch(
            "PID \(processID) has bundle ID \(runningApplication.bundleIdentifier ?? "<nil>"), expected \(expectedBundleIdentifier)"
        )
    }
    try validateGeometryEvidence(
        at: geometryEvidenceURL,
        processID: processID,
        captureSelector: captureSelector
    )

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard processExists(processID) else {
            throw WindowEvidenceError.processMismatch("PID \(processID) exited before capture")
        }

        let windows = matchingWindows(processID: processID)
        if windows.count == 1 {
            let window = windows[0]
            let result: [String: Any] = [
                "captureSelector": captureSelector,
                "processId": Int(window.ownerPID),
                "windowId": Int(window.id),
                "ownerName": window.ownerName,
                "windowTitle": window.title as Any,
                "logicalFrame": [
                    "x": window.frame.minX,
                    "y": window.frame.minY,
                    "width": window.frame.width,
                    "height": window.frame.height,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    throw WindowEvidenceError.timeout
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(70)
}
