import Foundation
import VtaMobileCore

/// The structured **authorization context** a step-up may carry — *what* the
/// operator is being asked to authorize (a Cierge cross-domain share, an
/// over-budget spend, a sensitive tool call), not just a `reason` line.
///
/// The engine surfaces it as a raw JSON string on `StepUpRequest`
/// (`authorizationContext`), decoded from the approve-request's reverse-DNS
/// `payload.ext` key `org.openvtc.authorization-context`. This mirrors the
/// producer schema (`cierge-orchestrator::authz_context::AuthorizationContext`,
/// `https://openvtc.org/cierge/authorization-context/0.1`).
public struct AuthorizationContext: Decodable, Equatable {
    public let type: String?
    /// The agent/domain making the ask.
    public let domain: String
    /// Tenant scope, when multi-tenant.
    public let tenant: String?
    /// One-line human summary — shown verbatim (it doubles as the step-up reason).
    public let summary: String
    /// Optional longer explanation.
    public let detail: String?
    public let risk: Risk
    /// The structured, kind-specific description of the ask.
    public let action: Action
    public let requestedAt: String?
    public let expiresAt: String?

    public enum Risk: String, Decodable {
        case low, medium, high
    }

    /// The kind-tagged action. `unknown` keeps a forward-compatible fallback so
    /// a newer producer variant still renders via `summary` instead of failing.
    public enum Action: Equatable {
        case share(
            from: String, to: String, fields: [String], capabilities: [String],
            purpose: String, ttlSeconds: UInt64)
        case spend(
            amountUsd: Double, budgetRemainingUsd: Double, provider: String, model: String)
        case tool(tool: String, argumentsSummary: String, target: String?)
        case lifecycle(operation: String, targetDomain: String)
        case custom(schema: String)
        case unknown(kind: String)

        /// A short kind label for the card chrome.
        public var kindLabel: String {
            switch self {
            case .share: return "Share"
            case .spend: return "Spend"
            case .tool: return "Tool"
            case .lifecycle: return "Lifecycle"
            case .custom: return "Custom"
            case .unknown(let kind): return kind
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, domain, tenant, summary, detail, risk, action, requestedAt, expiresAt
    }

    /// Decode from the raw JSON string the engine surfaces. Returns `nil` on any
    /// malformed input (the caller falls back to `reason`).
    public static func decode(fromJSON json: String) -> AuthorizationContext? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AuthorizationContext.self, from: data)
    }
}

extension AuthorizationContext.Action: Decodable {
    private enum K: String, CodingKey {
        case kind
        case from, to, fields, capabilities, purpose, ttlSeconds
        case amountUsd, budgetRemainingUsd, provider, model
        case tool, argumentsSummary, target
        case operation, targetDomain
        case schema
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "share":
            self = .share(
                from: try c.decode(String.self, forKey: .from),
                to: try c.decode(String.self, forKey: .to),
                fields: try c.decodeIfPresent([String].self, forKey: .fields) ?? [],
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
                purpose: try c.decodeIfPresent(String.self, forKey: .purpose) ?? "",
                ttlSeconds: try c.decodeIfPresent(UInt64.self, forKey: .ttlSeconds) ?? 0)
        case "spend":
            self = .spend(
                amountUsd: try c.decodeIfPresent(Double.self, forKey: .amountUsd) ?? 0,
                budgetRemainingUsd: try c.decodeIfPresent(Double.self, forKey: .budgetRemainingUsd)
                    ?? 0,
                provider: try c.decodeIfPresent(String.self, forKey: .provider) ?? "",
                model: try c.decodeIfPresent(String.self, forKey: .model) ?? "")
        case "tool":
            self = .tool(
                tool: try c.decodeIfPresent(String.self, forKey: .tool) ?? "",
                argumentsSummary: try c.decodeIfPresent(String.self, forKey: .argumentsSummary)
                    ?? "",
                target: try c.decodeIfPresent(String.self, forKey: .target))
        case "lifecycle":
            self = .lifecycle(
                operation: try c.decodeIfPresent(String.self, forKey: .operation) ?? "",
                targetDomain: try c.decodeIfPresent(String.self, forKey: .targetDomain) ?? "")
        case "custom":
            self = .custom(schema: try c.decodeIfPresent(String.self, forKey: .schema) ?? "")
        default:
            self = .unknown(kind: kind)
        }
    }
}

extension VtaMobileAgent {
    /// A parsed step-up ready to present for consent: the human `reason`, the
    /// echo fields, and the decoded [`AuthorizationContext`] when the request
    /// carries one (`nil` for a plain login-elevation step-up).
    public struct StepUpReview {
        public let reason: String
        public let subject: String
        public let sessionId: String
        public let targetAcr: String?
        public let authorizationContext: AuthorizationContext?
        /// The relying party that issued the request (the approve-request
        /// `issuer` — the VTA, or the domain on whose behalf it asks), shown so
        /// the operator knows *who* is asking. `nil` if the request omitted it.
        public let relyingParty: String?
    }

    /// Inspect an incoming approve-request (a bare document or a VTA `403` body)
    /// for display *before* approving — parses via the engine and decodes any
    /// structured authorization context.
    public static func inspect(approveRequest: String) throws -> StepUpReview {
        let doc = unwrapApproveRequest(approveRequest)
        let r = try parseStepUpRequest(json: doc)
        let ctx = r.authorizationContext.flatMap { AuthorizationContext.decode(fromJSON: $0) }
        return StepUpReview(
            reason: r.reason,
            subject: r.subject,
            sessionId: r.sessionId,
            targetAcr: r.targetAcr,
            authorizationContext: ctx,
            relyingParty: r.relyingParty)
    }
}
