import SwiftUI

/// Magnitude-tier color used for badges and map pins, matching the source
/// design's exact bands: <4 brand blue, 4-4.9 amber, 5-5.9 orange, >=6 red.
/// `cancelled` is a separate, orthogonal gray treatment, not a magnitude tier.
enum Severity: Comparable {
    case minor
    case moderate
    case strong
    case severe
    case cancelled

    static func from(magnitude: Double?, isCancel: Bool) -> Severity {
        if isCancel { return .cancelled }
        guard let magnitude else { return .minor }
        switch magnitude {
        case ..<4.0: return .minor
        case 4.0..<5.0: return .moderate
        case 5.0..<6.0: return .strong
        default: return .severe
        }
    }

    var color: Color {
        switch self {
        case .cancelled: return Color("GrayColor")
        case .minor: return Color("BrandColor")
        case .moderate: return Color("CautionColor")
        case .strong: return Color("StrongColor")
        case .severe: return Color("SevereColor")
        }
    }
}

/// Three-state overall system status shown on the Home banner -- distinct
/// from `Severity`: this is "is there anything to worry about right now
/// near you", not a per-event magnitude tier.
enum HomeBannerState {
    case normal
    case caution
    case alert

    var color: Color {
        switch self {
        case .normal: return Color("NormalColor")
        case .caution: return Color("CautionColor")
        case .alert: return Color("SevereColor")
        }
    }
}

/// The report-status badge shown on event rows/detail/alert screens.
enum ReportStatus {
    case preliminary
    case final
    case cancelled
    case training

    static func from(isFinal: Bool, isCancel: Bool, isTraining: Bool) -> ReportStatus {
        if isTraining { return .training }
        if isCancel { return .cancelled }
        if isFinal { return .final }
        return .preliminary
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .preliminary: return "status.preliminary"
        case .final: return "status.final"
        case .cancelled: return "status.cancelled"
        case .training: return "status.training"
        }
    }

    var color: Color {
        switch self {
        case .preliminary: return Color("BrandColor")
        case .final: return Color("NormalColor")
        case .cancelled: return Color("GrayColor")
        case .training: return Color("TestColor")
        }
    }
}
