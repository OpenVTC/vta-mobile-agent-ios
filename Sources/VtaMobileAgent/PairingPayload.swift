import Foundation

/// The first-run **pairing** payload encoded in a QR code an operator shows (from
/// the console/CLI) to bind this phone to their VTA + tenant in one scan —
/// instead of hand-typing the VTA DID / mediator DID in Settings.
///
/// Wire form: a compact `cierge-pair://v1?…` URL (also accepts a raw JSON object
/// for flexibility). The pairing conveys *where* to connect; registering this
/// device as the operator's delegated approver is a follow-up VTA call once
/// connected (that half needs a live VTA).
///
/// **What "where to connect" means now.** The agent reaches its VTA only over the
/// mediator (see ``VtaTransport``), so the DID pair — `did` + `mediator` — is the
/// address. `vta` (a REST base URL) survives as an optional legacy field only so
/// codes minted for older clients still scan; this agent ignores it, and a code
/// minted without one is perfectly valid.
public struct PairingPayload: Codable, Equatable {
    /// The VTA's DID — the only field a pairing code must carry.
    public let vtaDID: String
    /// The mediator DID to reach that VTA over.
    ///
    /// Optional on the wire, but the agent needs one to connect at all: a payload
    /// without it pairs the VTA DID and leaves the operator to fill the mediator
    /// in Settings.
    public let mediatorDID: String?
    /// The push-gateway base URL (optional). Still a URL: the gateway is the one
    /// service not reached over the mediator.
    public let gatewayURL: String?
    /// The operator/tenant this phone is being paired to (optional).
    public let tenant: String?
    /// The VTA's REST base URL — **legacy, ignored**. Kept so codes minted for
    /// pre-mediator clients still parse rather than being rejected as junk.
    public let vtaURL: String?

    public init(
        vtaDID: String, mediatorDID: String? = nil, gatewayURL: String? = nil,
        tenant: String? = nil, vtaURL: String? = nil
    ) {
        self.vtaDID = vtaDID
        self.mediatorDID = mediatorDID
        self.gatewayURL = gatewayURL
        self.tenant = tenant
        self.vtaURL = vtaURL
    }

    /// The custom URL scheme + version for the compact QR form.
    static let scheme = "cierge-pair"
    static let version = "v1"

    /// Encode to the compact `cierge-pair://v1?did=…&mediator=…&…` QR string.
    /// `vta` is emitted only when set, so a mediator-only pairing stays compact.
    public func encoded() -> String {
        var items = [URLQueryItem(name: "did", value: vtaDID)]
        if let mediatorDID { items.append(URLQueryItem(name: "mediator", value: mediatorDID)) }
        if let gatewayURL { items.append(URLQueryItem(name: "gateway", value: gatewayURL)) }
        if let tenant { items.append(URLQueryItem(name: "tenant", value: tenant)) }
        if let vtaURL { items.append(URLQueryItem(name: "vta", value: vtaURL)) }
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = Self.version
        comps.queryItems = items
        return comps.url?.absoluteString ?? ""
    }

    /// Parse a scanned string: the `cierge-pair://` URL form, or a raw JSON
    /// object. Returns `nil` if it isn't a well-formed pairing payload (so a
    /// stray QR is ignored rather than mis-applied).
    public static func parse(_ scanned: String) -> PairingPayload? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\(scheme)://") {
            return parseURL(trimmed)
        }
        // Raw JSON fallback.
        if let data = trimmed.data(using: .utf8),
            let p = try? JSONDecoder().decode(PairingPayload.self, from: data)
        {
            return p.vtaDID.isEmpty ? nil : p
        }
        return nil
    }

    private static func parseURL(_ url: String) -> PairingPayload? {
        guard let comps = URLComponents(string: url), comps.scheme == scheme else { return nil }
        let q = Dictionary(
            (comps.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        guard let did = q["did"], !did.isEmpty else { return nil }
        return PairingPayload(
            vtaDID: did, mediatorDID: q["mediator"], gatewayURL: q["gateway"],
            tenant: q["tenant"], vtaURL: q["vta"])
    }
}
