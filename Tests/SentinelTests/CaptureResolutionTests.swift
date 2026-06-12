import Testing
@testable import Sentinel

struct CaptureResolutionTests {
    @Test func parsesValidString() {
        #expect(CaptureResolution(string: "1920x1080") == CaptureResolution(width: 1920, height: 1080))
    }

    @Test func parsingIsCaseInsensitive() {
        #expect(CaptureResolution(string: "1920X1080") == CaptureResolution(width: 1920, height: 1080))
    }

    @Test(arguments: ["", "abc", "1920x", "x1080", "0x0", "-1920x1080", "1920x1080x3", "1920 x 1080"])
    func rejectsInvalidStrings(_ string: String) {
        #expect(CaptureResolution(string: string) == nil)
    }

    @Test func storageStringRoundTrips() {
        let resolution = CaptureResolution(width: 2560, height: 1440)
        #expect(resolution.storageString == "2560x1440")
        #expect(CaptureResolution(string: resolution.storageString) == resolution)
    }

    @Test func displayNameUsesMultiplicationSign() {
        #expect(CaptureResolution(width: 1920, height: 1080).displayName == "1920 × 1080")
    }
}

struct ResolutionListTests {
    @Test func dedupesFiltersAndSortsByArea() {
        let resolutions = CameraService.resolutions(fromDimensions: [
            (1920, 1080), (640, 480), (3840, 2160), (1920, 1080), (0, 0), (-1, 720), (640, 480),
        ])
        #expect(resolutions == [
            CaptureResolution(width: 640, height: 480),
            CaptureResolution(width: 1920, height: 1080),
            CaptureResolution(width: 3840, height: 2160),
        ])
    }

    @Test func equalAreasSortByWidth() {
        let resolutions = CameraService.resolutions(fromDimensions: [(480, 160), (320, 240)])
        #expect(resolutions == [
            CaptureResolution(width: 320, height: 240),
            CaptureResolution(width: 480, height: 160),
        ])
    }
}

struct BestMatchTests {
    private func candidate(_ width: Int, _ height: Int, fps: Double) -> CameraService.FormatCandidate {
        .init(resolution: CaptureResolution(width: width, height: height), maxFrameRate: fps)
    }

    @Test func prefersHighestFrameRateAmongMatches() {
        let candidates = [
            candidate(3840, 2160, fps: 5),
            candidate(1920, 1080, fps: 60),
            candidate(3840, 2160, fps: 30),
        ]
        #expect(CameraService.bestMatch(in: candidates, target: CaptureResolution(width: 3840, height: 2160)) == 2)
    }

    @Test func nilWhenTargetAbsent() {
        let candidates = [candidate(640, 480, fps: 30)]
        #expect(CameraService.bestMatch(in: candidates, target: CaptureResolution(width: 1920, height: 1080)) == nil)
    }

    @Test func firstWinsOnFrameRateTies() {
        let candidates = [
            candidate(1920, 1080, fps: 30),
            candidate(1920, 1080, fps: 30),
        ]
        #expect(CameraService.bestMatch(in: candidates, target: CaptureResolution(width: 1920, height: 1080)) == 0)
    }
}
