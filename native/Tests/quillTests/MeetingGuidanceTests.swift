import XCTest
@testable import quill

final class MeetingGuidanceTests: XCTestCase {
    private func meeting(issue: DeliveryFailure? = nil, legacy: Bool = false, localExport: Bool = false, attempts: Int = 0) -> RecentMeeting {
        RecentMeeting(directory: URL(fileURLWithPath: "/fixture/meeting"), title: "Weekly planning", started: nil,
            stage: .needsAttention, issue: issue, detail: LegacyReceiptReconciliation.reason, notes: nil,
            transcript: URL(fileURLWithPath: "/fixture/meeting/transcript.md"), completionAttempts: attempts,
            canVerifyLegacyReceipt: legacy, canRetryLocalExport: localExport)
    }
    func testLegacyReceiptHasPlainInstructionAndOneUnchargedNextStep() {
        let meeting = meeting(legacy: true)
        XCTAssertEqual(meeting.statusTitle, "Check saved notes")
        XCTAssertEqual(meeting.guidance.action, .findNotes)
        XCTAssertEqual(meeting.guidance.button, "Find my notes")
        XCTAssertFalse(meeting.guidance.message.lowercased().contains("fingerprint"))
        XCTAssertTrue(meeting.guidance.footnote.contains("No AI generation"))
        XCTAssertEqual(meeting.detail, LegacyReceiptReconciliation.reason, "Stored diagnostic evidence stays intact")
    }
    func testLocalExportIsRecoveredOfflineBeforeAnyGatewayVerification() {
        let meeting = meeting(legacy: true, localExport: true)
        XCTAssertEqual(meeting.guidance.action, .saveLocalNotes)
        XCTAssertTrue(meeting.guidance.message.contains("saved on the Gateway"))
    }
    func testSignInAndMissingModelTakePriorityOverAnUnusableSavedNotesCheck() {
        XCTAssertEqual(meeting(issue: .signInRequired, legacy: true).guidance.action, .signIn)
        let missing = DeliveryFailure(code: "local_model_missing", detail: "fixture", retryable: false, completionAttempted: false)
        XCTAssertEqual(meeting(issue: missing, legacy: true).guidance.action, .downloadModel)
    }
    func testExhaustedAIBudgetDoesNotRecommendAnotherPaidAttempt() {
        let failure = DeliveryFailure(code: "ai_retry_limit", detail: "fixture", retryable: false, completionAttempted: true)
        let value = meeting(issue: failure, attempts: 3)
        XCTAssertEqual(value.guidance.action, .transcriptOnly)
        XCTAssertFalse(value.canRetryAINotes)
        XCTAssertEqual(value.completionAttempts, 3)
    }
    func testUnknownCauseOffersSupportInsteadOfInventingARepair() {
        XCTAssertEqual(meeting().guidance.action, .supportReport)
        XCTAssertTrue(meeting().guidance.footnote.contains("excludes audio"))
    }
    func testSavedCaptureGapsRecommendReviewRatherThanAnotherUpload() {
        var value = meeting()
        value.hasCaptureWarnings = true
        XCTAssertEqual(value.guidance.action, .openTranscript)
        XCTAssertEqual(value.statusTitle, "Review gaps in the transcript")
        XCTAssertTrue(value.guidance.message.contains("notes are saved"))
    }
    func testChangedSavedTranscriptRequiresReviewRatherThanAnOverwrite() {
        let failure = DeliveryFailure(code: "revision_conflict", detail: "fixture", retryable: false, completionAttempted: false)
        XCTAssertEqual(meeting(issue: failure).guidance.action, .openTranscript)
    }
}
