import Foundation

/// A pairing — scanned from a QR code or typed in Settings — that has passed
/// ``PairingPolicy`` and is ready to be shown to the operator. Nothing in it has
/// been saved or connected to yet.
public struct PairingReview: Identifiable, Equatable {
    /// The VTA DID being paired: the only issuer this device will accept
    /// step-up and task-consent requests from once confirmed.
    public let vtaDID: String
    /// The mediator, taken from the VTA's DID document. A mediator carried by
    /// the pairing code is only ever a cross-check against this.
    public let mediatorDID: String
    /// The push gateway, if one was supplied. Already passed
    /// ``GatewayURLPolicy/validateStructure(_:)``.
    public let gatewayURL: URL?
    /// ``GatewayURLError/hostNotBoundToVta(_:)`` when the gateway's host is
    /// outside the VTA's domain — shown as a warning, never dropped.
    public let gatewayWarning: GatewayURLError?
    /// The tenant as stated by the pairing code. Unverified, display only.
    public let tenant: String?
    /// The VTA this device is paired with right now, if any.
    public let replacingVtaDID: String?

    public var id: String { vtaDID }

    /// The `did:web` / `did:webvh` domain of the VTA, for display.
    public var vtaDomain: String? { GatewayURLPolicy.webDomain(ofDID: vtaDID) }

    /// Whether confirming would replace a *different* VTA. That changes whose
    /// requests this device approves, so it needs device-owner authentication
    /// and a destructive-change warning.
    public var replacesDifferentVta: Bool {
        guard let replacingVtaDID else { return false }
        return replacingVtaDID != vtaDID
    }
}

/// Why a pairing was refused before it could be shown for confirmation.
public enum PairingRejection: Error, Equatable {
    /// The VTA identifier is not a DID.
    case invalidVtaDID
    /// The VTA's DID document advertises no DIDComm mediator, so there is no
    /// authoritative mediator to pair with.
    case noDidcommService
    /// The pairing code named a different mediator from the VTA's DID document.
    case mediatorMismatch(qr: String, didDoc: String)
    /// The push gateway URL broke a hard rule.
    case gateway(GatewayURLError)
}

extension PairingRejection: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidVtaDID:
            return "The VTA identifier is not a valid DID."
        case .noDidcommService:
            return "The VTA's DID document advertises no mediator (#vta-didcomm service)."
        case .mediatorMismatch(let qr, let didDoc):
            return "The pairing code names mediator \(qr), but the VTA's DID document names \(didDoc)."
        case .gateway(let error):
            return error.localizedDescription
        }
    }
}

/// The decision between "a pairing was read" and "show it for confirmation".
/// Pure: the caller resolves the VTA's DID document first and passes in the
/// mediator it advertises.
public enum PairingPolicy {
    /// - Parameters:
    ///   - payload: what was scanned or typed.
    ///   - resolvedMediator: the mediator DID from the VTA's DID document
    ///     (`#vta-didcomm`), or `nil` if it advertises none.
    ///   - currentVtaDID: the VTA this device is paired with now, if any.
    public static func review(
        _ payload: PairingPayload, resolvedMediator: String?, currentVtaDID: String?
    ) -> Result<PairingReview, PairingRejection> {
        guard let vtaDID = nonEmpty(payload.vtaDID), isDid(vtaDID) else {
            return .failure(.invalidVtaDID)
        }
        guard let mediatorDID = nonEmpty(resolvedMediator) else {
            return .failure(.noDidcommService)
        }
        if let stated = nonEmpty(payload.mediatorDID), stated != mediatorDID {
            return .failure(.mediatorMismatch(qr: stated, didDoc: mediatorDID))
        }

        var gatewayURL: URL?
        var gatewayWarning: GatewayURLError?
        if let raw = nonEmpty(payload.gatewayURL) {
            switch GatewayURLPolicy.validateStructure(raw) {
            case .failure(let error):
                return .failure(.gateway(error))
            case .success(let url):
                gatewayURL = url
                gatewayWarning = GatewayURLPolicy.bindingWarning(for: url, vtaDID: vtaDID)
            }
        }

        return .success(
            PairingReview(
                vtaDID: vtaDID,
                mediatorDID: mediatorDID,
                gatewayURL: gatewayURL,
                gatewayWarning: gatewayWarning,
                tenant: nonEmpty(payload.tenant),
                replacingVtaDID: nonEmpty(currentVtaDID)))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    /// `did:<method>:<id>` with no whitespace.
    private static func isDid(_ s: String) -> Bool {
        let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "did" && !parts[1].isEmpty && !parts[2].isEmpty
            && !s.contains(where: { $0.isWhitespace })
    }
}
