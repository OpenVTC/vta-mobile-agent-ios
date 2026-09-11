import XCTest

@testable import VtaMobileAgent

/// When a verified step-up may be ratified without the operator.
final class StepUpPolicyTests: XCTestCase {
    /// A background wake never auto-approves, whatever the setting.
    func testBackgroundSignInIsQueued() {
        XCTAssertEqual(
            StepUpPolicy.decide(
                hasAuthorizationContext: false, appActive: false, autoApproveSignIns: true),
            .queueForReview)
        XCTAssertEqual(
            StepUpPolicy.decide(
                hasAuthorizationContext: false, appActive: false, autoApproveSignIns: false),
            .queueForReview)
    }

    /// The setting is off by default, and off means ask.
    func testForegroundSignInWithSettingOffIsQueued() {
        XCTAssertEqual(
            StepUpPolicy.decide(
                hasAuthorizationContext: false, appActive: true, autoApproveSignIns: false),
            .queueForReview)
    }

    func testForegroundSignInWithSettingOnIsAutoApproved() {
        XCTAssertEqual(
            StepUpPolicy.decide(
                hasAuthorizationContext: false, appActive: true, autoApproveSignIns: true),
            .autoApprove)
    }

    /// A request carrying an authorization context always asks.
    func testAnyAuthorizationContextIsQueued() {
        for appActive in [false, true] {
            for autoApproveSignIns in [false, true] {
                XCTAssertEqual(
                    StepUpPolicy.decide(
                        hasAuthorizationContext: true, appActive: appActive,
                        autoApproveSignIns: autoApproveSignIns),
                    .queueForReview, "appActive=\(appActive) setting=\(autoApproveSignIns)")
            }
        }
    }
}
