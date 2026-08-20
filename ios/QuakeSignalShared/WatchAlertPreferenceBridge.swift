import CoreFoundation
import Foundation

#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

/// Strict, versioned application-context payload used only to mirror the
/// iPhone's selected alert sound to its companion Watch app. This bridge does
/// not transfer earthquake events and is not a notification-delivery path.
enum WatchAlertPreferenceContext {
    static let schemaVersion = 1
    static let schemaVersionKey = "schemaVersion"
    static let alertSoundKey = "alertSound"
    static let watchDefaultsKey = "settings.alertSound"

    static func applicationContext(
        for preference: AlertSoundPreference
    ) -> [String: Any] {
        [
            schemaVersionKey: schemaVersion,
            alertSoundKey: preference.rawValue,
        ]
    }

    static func preference(from applicationContext: [String: Any]) -> AlertSoundPreference? {
        guard Set(applicationContext.keys) == [schemaVersionKey, alertSoundKey],
              hasExactSchemaVersion(applicationContext[schemaVersionKey]),
              let rawValue = applicationContext[alertSoundKey] as? String else {
            return nil
        }
        return AlertSoundPreference(rawValue: rawValue)
    }

    private static func hasExactSchemaVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return false
        }
        return number.int64Value == Int64(schemaVersion)
    }

    static func storedPreference(defaults: UserDefaults = .standard) -> AlertSoundPreference {
        defaults.string(forKey: watchDefaultsKey)
            .flatMap(AlertSoundPreference.init(rawValue:))
            ?? .system
    }

    @discardableResult
    static func persist(
        applicationContext: [String: Any],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let preference = preference(from: applicationContext) else { return false }
        defaults.set(preference.rawValue, forKey: watchDefaultsKey)
        return true
    }

    static func normalizeStoredPreference(defaults: UserDefaults = .standard) {
        defaults.set(storedPreference(defaults: defaults).rawValue, forKey: watchDefaultsKey)
    }
}

enum WatchAlertPreferenceBridge {
    /// Activates the phone side and immediately mirrors the current preference
    /// when the paired Watch route is available. A later activation callback
    /// retries with the then-current value.
    static func activatePhone(current preference: AlertSoundPreference) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        PhoneAlertPreferenceSession.shared.activate(current: preference)
#endif
    }

    /// Keeps the iPhone preference authoritative. Catalyst, TV, and Vision
    /// compile this shared call as a deliberate no-op.
    static func synchronizeFromPhone(_ preference: AlertSoundPreference) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        PhoneAlertPreferenceSession.shared.synchronize(preference)
#endif
    }

    /// Receives only a validated preference context. Screenshot automation
    /// skips this activation so captures never depend on paired-device state.
    static func activateWatch() {
#if os(watchOS)
        WatchAlertPreferenceSession.shared.activate()
#endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private final class PhoneAlertPreferenceSession: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneAlertPreferenceSession()

    private let session: WCSession?

    private override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func activate(current preference: AlertSoundPreference) {
        guard let session else { return }
        session.delegate = self
        session.activate()
        synchronize(preference)
    }

    func synchronize(_ preference: AlertSoundPreference) {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return
        }
        try? session.updateApplicationContext(
            WatchAlertPreferenceContext.applicationContext(for: preference)
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        synchronize(WatchAlertPreferenceContext.storedPreference())
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        synchronize(WatchAlertPreferenceContext.storedPreference())
    }
}
#elseif os(watchOS)
private final class WatchAlertPreferenceSession: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchAlertPreferenceSession()

    private let session: WCSession?

    private override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func activate() {
        WatchAlertPreferenceContext.normalizeStoredPreference()
        guard let session else { return }
        session.delegate = self
        session.activate()
        if !session.receivedApplicationContext.isEmpty {
            WatchAlertPreferenceContext.persist(
                applicationContext: session.receivedApplicationContext
            )
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated,
              error == nil,
              !session.receivedApplicationContext.isEmpty else {
            return
        }
        WatchAlertPreferenceContext.persist(
            applicationContext: session.receivedApplicationContext
        )
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        WatchAlertPreferenceContext.persist(applicationContext: applicationContext)
    }
}
#endif
