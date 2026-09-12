import Foundation
import XCTest

@testable import VtaMobileAgent

/// The presence rule for an operator decision: an approval is authenticated,
/// a denial is not.
///
/// The closure passed to ``ApprovalGate/submit(approving:reason:_:)`` is the
/// transport call at every call site, so a spy closure that is never run is the
/// assertion that the approval never reached the VTA.
final class ApprovalGateTests: XCTestCase {
    func testAnApprovalNeedsTheDeviceOwner() async {
        let authenticator = FakeAuthenticator(result: true)
        let gate = ApprovalGate(authenticator: authenticator)
        var sent = 0

        let outcome = try? await gate.submit(approving: true, reason: "Approve this request") {
            sent += 1
            return "submitted"
        }

        XCTAssertEqual(outcome, "submitted")
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(authenticator.reasons, ["Approve this request"])
    }

    /// The device owner said no (or the device has no passcode or biometrics, or
    /// the prompt was cancelled): nothing is signed and nothing is submitted, so
    /// the request stays pending for a later attempt.
    func testARefusedCheckSendsNothing() async {
        let authenticator = FakeAuthenticator(result: false)
        let gate = ApprovalGate(authenticator: authenticator)
        var sent = 0

        do {
            _ = try await gate.submit(approving: true, reason: "Approve this request") {
                sent += 1
                return "submitted"
            }
            XCTFail("the approval was submitted without the device owner")
        } catch {
            XCTAssertEqual(error as? ApprovalGateError, .notAuthorized)
        }

        XCTAssertEqual(sent, 0, "an unauthorized approval must not reach the transport")
        XCTAssertEqual(authenticator.reasons.count, 1, "asked exactly once, no reuse window")
    }

    /// A denial goes out unauthenticated — deliberately. A refusal that couldn't
    /// be sent would leave the request pending at the VTA.
    func testADenialIsNotGated() async {
        let authenticator = FakeAuthenticator(result: false)
        let gate = ApprovalGate(authenticator: authenticator)
        var sent = 0

        let outcome = try? await gate.submit(approving: false, reason: "unused") {
            sent += 1
            return "denied"
        }

        XCTAssertEqual(outcome, "denied")
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(authenticator.reasons.isEmpty, "a denial must not prompt")
    }

    func testAFailingSubmissionSurfacesItsOwnError() async {
        let gate = ApprovalGate(authenticator: FakeAuthenticator(result: true))

        do {
            try await gate.submit(approving: true, reason: "Approve this request") {
                throw AgentError.badResponse("transport down")
            }
            XCTFail("the transport error was swallowed")
        } catch {
            XCTAssertNotEqual(error as? ApprovalGateError, .notAuthorized)
        }
    }
}

/// A ``DeviceOwnerAuthenticator`` that answers without biometrics, recording
/// what it was asked to confirm.
private final class FakeAuthenticator: DeviceOwnerAuthenticator {
    private let result: Bool
    var reasons: [String] = []

    init(result: Bool) { self.result = result }

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return result
    }
}
