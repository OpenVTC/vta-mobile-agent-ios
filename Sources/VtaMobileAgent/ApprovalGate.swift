import Foundation

/// Why an operator's decision was not submitted.
public enum ApprovalGateError: Error, LocalizedError, Equatable {
    /// The device-owner check failed, was cancelled, or the device has no
    /// passcode or biometrics enrolled. Nothing was sent.
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Not approved — this device couldn't confirm it's you. "
                + "Approving needs Face ID, Touch ID or the device passcode."
        }
    }
}

/// Requires the device owner to be present before an **approval** is sent, and
/// stays out of the way of a **denial**.
///
/// Why here and not in the Keychain: the holder seed is read once per launch and
/// then lives in memory for the session — the engine derives the DIDComm keys
/// from it and signs every message with it — so the item's protection class can
/// gate that one read, never an individual signature. Presence has to be checked
/// where the operator actually decides something.
///
/// Saying *no* is never gated. A refusal that couldn't be sent would leave the
/// request pending at the VTA, and the safe outcome of a failed check is that
/// nothing is authorized.
///
/// A device with **no passcode and no biometrics** cannot authenticate, so on
/// such a device an approval is refused rather than sent unchecked.
public struct ApprovalGate {
    private let authenticator: DeviceOwnerAuthenticator

    public init(authenticator: DeviceOwnerAuthenticator) {
        self.authenticator = authenticator
    }

    /// Submit one decision.
    ///
    /// - Parameters:
    ///   - approving: `true` for an approval — the device owner is
    ///     authenticated first and `send` is never reached if that fails, so an
    ///     approval cannot go out without presence. `false` for a denial, which
    ///     is submitted straight away.
    ///   - reason: what the system prompt tells the operator they are
    ///     confirming. Unused for a denial.
    ///   - send: signs and submits the decision. At every call site this is the
    ///     transport call, so "the check failed" and "nothing was sent" are the
    ///     same thing.
    /// - Throws: ``ApprovalGateError/notAuthorized`` when presence was required
    ///   and not confirmed, else whatever `send` throws.
    @discardableResult
    public func submit<T>(
        approving: Bool, reason: String, _ send: () async throws -> T
    ) async throws -> T {
        if approving {
            guard await authenticator.authenticate(reason: reason) else {
                throw ApprovalGateError.notAuthorized
            }
        }
        return try await send()
    }
}
