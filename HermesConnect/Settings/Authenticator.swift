import LocalAuthentication

/// Face ID with passcode fallback for App Lock (LocalAuthentication `.deviceOwnerAuthentication`).
@MainActor
enum Authenticator {
    enum Biometry: Sendable, CaseIterable {
        case faceID, touchID, opticID, none
    }

    static func biometry() -> Biometry {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// False when the device has no passcode. Then App Lock cannot ask for anything.
    static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Ask for Face ID, then the passcode if Face ID fails. Returns false on failure or cancel.
    static func authenticate() async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Hermes")
        } catch {
            return false
        }
    }

    /// One name for the unlock method, from `LABiometryType`. "Passcode" only when there is no biometry.
    nonisolated static func methodName(for biometry: Biometry) -> String {
        switch biometry {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "Passcode"
        }
    }

    nonisolated static func unlockButtonTitle(for biometry: Biometry) -> String {
        "Unlock with \(methodName(for: biometry))"
    }

    nonisolated static func appLockToggleTitle(for biometry: Biometry) -> String {
        "App Lock (\(methodName(for: biometry)))"
    }

    nonisolated static func appLockFooter(for biometry: Biometry) -> String {
        "Require \(methodName(for: biometry)) when Hermes opens."
    }

    static var unlockButtonTitle: String { unlockButtonTitle(for: biometry()) }

    static var unlockButtonSymbol: String {
        switch biometry() {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock.open"
        }
    }

    static var appLockToggleTitle: String { appLockToggleTitle(for: biometry()) }
    static var appLockFooter: String { appLockFooter(for: biometry()) }
}
