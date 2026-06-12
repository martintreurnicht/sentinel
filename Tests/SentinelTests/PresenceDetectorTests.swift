import Testing
@testable import Sentinel

// The Vision requests need a live camera frame; these cover the pure decision
// the detector applies to Vision's outputs.

@Test func faceCountsInBothModes() {
    #expect(PresenceDetector.verdict(faceCount: 1, personCoverage: 0, mode: .person, minimumCoverage: 0.01) == .present)
    #expect(PresenceDetector.verdict(faceCount: 2, personCoverage: 0, mode: .face, minimumCoverage: 0.01) == .present)
}

@Test func coverageWithoutFaceIsPresentInPersonMode() {
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0.11, mode: .person, minimumCoverage: 0.01) == .present)
}

@Test func coverageIsIgnoredInFaceMode() {
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0.11, mode: .face, minimumCoverage: 0.01) == .absent)
}

@Test func coverageBelowThresholdIsAbsent() {
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0.005, mode: .person, minimumCoverage: 0.01) == .absent)
}

@Test func coverageAtThresholdIsPresent() {
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0.01, mode: .person, minimumCoverage: 0.01) == .present)
}

@Test func emptyFrameIsAbsentInBothModes() {
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0, mode: .person, minimumCoverage: 0.01) == .absent)
    #expect(PresenceDetector.verdict(faceCount: 0, personCoverage: 0, mode: .face, minimumCoverage: 0.01) == .absent)
}
