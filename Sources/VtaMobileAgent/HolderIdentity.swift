import CryptoKit
import Foundation
import VtaMobileCore

/// Errors surfaced by the agent layer (key custody, transport, engine).
public enum AgentError: Error, LocalizedError {
    case keychain(OSStatus)
    case http(status: Int, body: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Keychain error (OSStatus \(status))"
        case let .http(status, body):
            let snippet = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "HTTP \(status): \(snippet)"
        case let .badResponse(msg):
            return "Unexpected response: \(msg)"
        }
    }
}

/// The device's holder identity: a software-held Ed25519 key (CryptoKit),
/// persisted in the Keychain, exposed to the engine as a [`Signer`].
///
/// Ed25519 (not Secure Enclave) because the VTA authenticates documents with an
/// `eddsa-jcs-2022` Data-Integrity proof, and the Secure Enclave is P-256-only.
/// This is the "Tier 2" software-held custody profile; a future Tier-1 build can
/// swap in a P-256 enclave key behind this same `Signer` seam once the VTA
/// accepts an ES256/P-256 proof.
public final class HolderIdentity: Signer {
    private let privateKey: Curve25519.Signing.PrivateKey

    /// This holder's `did:key` (Ed25519). Used as the document `issuer` and the
    /// proof `verificationMethod`; enroll it in the VTA's ACL to authorize it.
    public let didKey: String

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.didKey = HolderIdentity.deriveDidKey(privateKey.publicKey)
    }

    /// Load the device holder key from the Keychain, generating and persisting a
    /// fresh one on first launch. The identity is stable across app launches so
    /// an enrolled `did:key` keeps working.
    public static func loadOrCreate(account: String = "holder-ed25519") throws -> HolderIdentity {
        if let raw = try Keychain.read(account: account) {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return HolderIdentity(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try Keychain.write(account: account, data: key.rawRepresentation)
        return HolderIdentity(privateKey: key)
    }

    /// `did:key` for an Ed25519 public key: multibase-base58btc of the
    /// multicodec-tagged (`0xed 0x01`) raw public key, `z`-prefixed.
    static func deriveDidKey(_ publicKey: Curve25519.Signing.PublicKey) -> String {
        var bytes: [UInt8] = [0xed, 0x01]
        bytes.append(contentsOf: publicKey.rawRepresentation)
        return "did:key:z" + Base58.encode(bytes)
    }

    // MARK: Signer (UniFFI callback into the engine)

    public func did() -> String { didKey }

    /// Sign the engine-supplied `eddsa-jcs-2022` input with the holder key.
    /// Private key material never crosses the FFI boundary.
    public func sign(payload: Data) throws -> Data {
        try privateKey.signature(for: payload)
    }

    /// Derive this identity's DIDComm holder keys — the X25519 key-agreement
    /// keypair (Edwards→Montgomery from the Ed25519 signing key) the engine
    /// needs to stand up a `DidcommSession` for unpacking inbound messages.
    ///
    /// The Ed25519 seed crosses the FFI here (the engine derives X25519 from
    /// it); it stays on-device. New in engine v0.2.0 (`didcomm_holder_keys`).
    public func didcommHolderKeys() throws -> HolderKeys {
        try VtaMobileCore.didcommHolderKeys(
            did: didKey, signingPrivateEd25519: privateKey.rawRepresentation)
    }

    /// Open a live DIDComm session to `mediatorDid` as this holder — the inbound
    /// channel for VTA-pushed step-up approve-requests. The returned
    /// `MediatorSession` authenticates to the mediator (challenge-auth), then
    /// `receiveNext` pulls messages off message-pickup 3.0 over a live WebSocket.
    /// `vtaDid` is the expected sender the engine resolves to authenticate
    /// inbound authcrypt.
    ///
    /// The Ed25519 seed crosses the FFI here (the engine derives the X25519
    /// key-agreement key it authenticates with); it stays on-device. Keeping
    /// `connect` on `HolderIdentity` keeps `privateKey` encapsulated — callers
    /// never touch the raw seed.
    public func connectMediator(vtaDid: String, mediatorDid: String) async throws -> MediatorSession
    {
        try await MediatorSession.connect(
            holderDid: didKey,
            holderSigningPrivateEd25519: privateKey.rawRepresentation,
            vtaDid: vtaDid,
            mediatorDid: mediatorDid)
    }

    /// TSP counterpart of ``connectMediator(vtaDid:mediatorDid:)``: open the
    /// holder's **TSP** websocket to the mediator so the app can receive
    /// VTA-pushed Trust Tasks over TSP instead of DIDComm. No `vtaDid` is needed
    /// — a TSP receive session takes whatever the mediator delivers to this
    /// holder and doesn't gate on a conversing peer.
    ///
    /// Note the one-socket-per-DID rule (ADR 0005): a holder can hold a DIDComm
    /// *or* a TSP mediator socket, not both at once — the caller picks the
    /// transport for its inbox rather than running both concurrently.
    public func connectMediatorTsp(mediatorDid: String) async throws -> TspMediatorSession {
        try await TspMediatorSession.connect(
            holderDid: didKey,
            holderSigningPrivateEd25519: privateKey.rawRepresentation,
            mediatorDid: mediatorDid)
    }
}

/// Minimal Keychain wrapper for a single generic-password item (the holder key).
enum Keychain {
    private static let service = "org.openvtc.vta.agent"

    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AgentError.keychain(status)
        }
        return data
    }

    static func write(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // idempotent replace
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentError.keychain(status) }
    }
}

/// Bitcoin-alphabet Base58 (multibase `z`) encoder — small, dependency-free.
enum Base58 {
    private static let alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func encode(_ bytes: [UInt8]) -> String {
        var digits: [Int] = []
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        var result = ""
        for byte in bytes { // leading zero bytes → leading '1's
            if byte == 0 { result.append(alphabet[0]) } else { break }
        }
        for d in digits.reversed() { result.append(alphabet[d]) }
        return result
    }
}
