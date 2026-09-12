import Foundation

/// What to do with an inbound step-up request whose proof has already been
/// verified against the enrolled issuers.
public enum StepUpDecision: Equatable {
    /// Ratify it now with the holder key, without asking the operator.
    case autoApprove
    /// Queue it for the operator's Approve/Deny and post a notification.
    case queueForReview
}

/// The one place that decides whether a step-up may be ratified without the
/// operator seeing it.
///
/// Only a plain sign-in step-up (no authorization context) can qualify, and
/// only when the operator has turned on "Auto-approve sign-ins" *and* the app
/// is in the foreground. Everything else is queued: any request carrying an
/// authorization context, and every request that arrives while the app is not
/// active — a background push wake included — so an unattended phone never
/// approves on its own.
public enum StepUpPolicy {
    public static func decide(
        hasAuthorizationContext: Bool, appActive: Bool, autoApproveSignIns: Bool
    ) -> StepUpDecision {
        guard !hasAuthorizationContext, appActive, autoApproveSignIns else {
            return .queueForReview
        }
        return .autoApprove
    }
}
