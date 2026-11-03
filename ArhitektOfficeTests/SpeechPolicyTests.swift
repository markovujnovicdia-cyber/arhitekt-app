import XCTest
@testable import ArhitektOffice

final class SpeechPolicyTests: XCTestCase {
    func testAudioNeverUsesNetworkWithoutConsentWhenLocalRecognitionIsUnavailable() {
        XCTAssertEqual(SpeechRecognitionPolicy.mode(supportsOnDevice: false, networkConsent: false), .requiresConsent)
    }

    func testExplicitConsentAllowsNetworkFallback() {
        XCTAssertEqual(SpeechRecognitionPolicy.mode(supportsOnDevice: false, networkConsent: true), .network)
    }

    func testLocalProcessingAlwaysTakesPrecedenceOverNetworkConsent() {
        XCTAssertEqual(SpeechRecognitionPolicy.mode(supportsOnDevice: true, networkConsent: true), .onDevice)
        XCTAssertEqual(SpeechRecognitionPolicy.mode(supportsOnDevice: true, networkConsent: false), .onDevice)
    }
}
