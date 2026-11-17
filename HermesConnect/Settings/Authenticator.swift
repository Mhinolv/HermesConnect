import LocalAuthentication

/// Face ID with passcode fallback for App Lock (LocalAuthentication `.deviceOwnerAuthentication`).
@MainActor
enum Authenticator {
    enum Biometry {
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

    static var unlockButtonTitle: String {
        switch biometry() {
        case .faceID: "Unlock with Face ID"
        case .touchID: "Unlock with Touch ID"
        case .opticID: "Unlock with Optic ID"
        case .none: "Unlock with Passcode"
        }
    }

    static var unlockButtonSymbol: String {
        switch biometry() {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock.open"
        }
    }

    static var appLockToggleTitle: String {
        biometry() == .none ? "App Lock (Passcode)" : "App Lock"
    }
}
