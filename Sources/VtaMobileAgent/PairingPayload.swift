import Foundation

/// The first-run **pairing** payload encoded in a QR code an operator shows (from
/// the console/CLI) to bind this phone to their VTA + tenant in one scan —
/// instead of hand-typing the VTA DID / URL / mediator in Settings.
///
/// Wire form: a compact `cierge-pair://v1?…` URL (also accepts a raw JSON object
/// for flexibility). The pairing conveys *where* to connect; registering this
/// device as the operator's delegated approver is a follow-up VTA call once
/// connected (that half needs a live VTA).
public struct PairingPayload: Codable, Equatable {
    /// The VTA's base URL (REST).
    public let vtaURL: String
    /// The VTA's DID.
    public let vtaDID: String
    /// The mediator DID for the DIDComm approver path (optional — REST-only VTAs
    /// omit it).
    public let mediatorDID: String?
    /// The push-gateway base URL (optional).
    public let gatewayURL: String?
    /// The operator/tenant this phone is being paired to (optional).
    public let tenant: String?

    public init(
        vtaURL: String, vtaDID: String, mediatorDID: String? = nil,
        gatewayURL: String? = nil, tenant: String? = nil
    ) {
        self.vtaURL = vtaURL
        self.vtaDID = vtaDID
        self.mediatorDID = mediatorDID
        self.gatewayURL = gatewayURL
        self.tenant = tenant
    }

    /// The custom URL scheme + version for the compact QR form.
    static let scheme = "cierge-pair"
    static let version = "v1"

    /// Encode to the compact `cierge-pair://v1?vta=…&did=…&…` QR string.
    public func encoded() -> String {
        var items = [
            URLQueryItem(name: "vta", value: vtaURL),
            URLQueryItem(name: "did", value: vtaDID),
        ]
        if let mediatorDID { items.append(URLQueryItem(name: "mediator", value: mediatorDID)) }
        if let gatewayURL { items.append(URLQueryItem(name: "gateway", value: gatewayURL)) }
        if let tenant { items.append(URLQueryItem(name: "tenant", value: tenant)) }
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
            return p.vtaURL.isEmpty || p.vtaDID.isEmpty ? nil : p
        }
        return nil
    }

    private static func parseURL(_ url: String) -> PairingPayload? {
        guard let comps = URLComponents(string: url), comps.scheme == scheme else { return nil }
        let q = Dictionary(
            (comps.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        guard let vta = q["vta"], !vta.isEmpty, let did = q["did"], !did.isEmpty else { return nil }
        return PairingPayload(
            vtaURL: vta, vtaDID: did,
            mediatorDID: q["mediator"], gatewayURL: q["gateway"], tenant: q["tenant"])
    }
}
