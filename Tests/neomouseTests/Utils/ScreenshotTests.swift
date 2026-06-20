import Foundation
import Testing

import neomouseUtils

/// `Screenshot.isTCCError` classifies whether a capture error is the
/// "Screen Recording permission missing" case (SCStreamError -3801), which
/// CoreOperations uses to swap a raw error for an actionable toast. Pure
/// NSError inspection — no capture is performed.
@Suite("Screenshot.isTCCError")
struct ScreenshotTests {
    private static let scDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    @Test("SCStream user-declined (-3801) is the TCC error")
    func userDeclined() {
        let error = NSError(domain: Self.scDomain, code: -3801)
        #expect(Screenshot.isTCCError(error))
    }

    @Test("a different SCStream code is not the TCC error")
    func otherCode() {
        let error = NSError(domain: Self.scDomain, code: -3802)
        #expect(!Screenshot.isTCCError(error))
    }

    @Test("the right code in a different domain is not the TCC error")
    func otherDomain() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: -3801)
        #expect(!Screenshot.isTCCError(error))
    }
}
