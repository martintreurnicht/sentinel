import CoreVideo
import Vision

/// Decides present / absent / too-dark for a captured frame.
///
/// Presence means a face or, in `.person` mode, a person visible in the frame. Face
/// detection is frontal-biased: leaning on an elbow or watching a second display angles
/// the face away from the camera and it stops registering, even though the person is
/// plainly in the chair. Person segmentation (the model behind video-call background
/// blur, built for exactly this close-range framing) still sees them, so only an empty
/// chair — not an averted gaze — reads as absent. The rectangle/pose person detectors
/// (VNDetectHumanRectanglesRequest, VNDetectHumanBodyPoseRequest) were measured blind
/// at seated webcam distance and are deliberately not used.
///
/// The luminance guard exists so a covered lens, a clamshell lid, or a camera staring
/// into darkness reads as "inconclusive" rather than "absent" — absence may lock the
/// screen, so it must only ever come from a well-lit frame with no detectable person.
struct PresenceDetector: Sendable {
    enum Verdict: Sendable {
        case present
        case absent
        case tooDark
    }

    /// Mean luma (0...1, full range) below which a frame is considered unjudgeable.
    var darknessThreshold: Double = 0.05

    /// Minimum fraction of frame pixels the segmentation mask must mark as person for
    /// the frame to count as someone present. Measured on a built-in MacBook camera:
    /// an empty room reads 0.000, a seated or passing user 0.03–0.28.
    var personCoverageThreshold: Double = 0.01

    func analyze(_ frame: CameraService.Frame, mode: DetectionMode) throws -> Verdict {
        if let luminance = Self.meanLuminance(of: frame.pixelBuffer), luminance < darknessThreshold {
            Log.camera.info("frame too dark (mean luma \(luminance, format: .fixed(precision: 3)))")
            return .tooDark
        }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)

        guard mode == .person else {
            try handler.perform([faceRequest])
            let faceCount = faceRequest.results?.count ?? 0
            Log.camera.info("face detection found \(faceCount) face(s)")
            return faceCount > 0 ? .present : .absent
        }

        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([faceRequest, segmentation])

        let faceCount = faceRequest.results?.count ?? 0
        var coverage = 0.0
        if let mask = segmentation.results?.first?.pixelBuffer {
            coverage = max(0, Self.maskCoverage(of: mask))
        }
        Log.camera.info("detection: \(faceCount) face(s), person coverage \(coverage, format: .fixed(precision: 3))")

        let threshold = personCoverageThreshold
        let verdict = Self.verdict(
            faceCount: faceCount,
            personCoverage: coverage,
            mode: mode,
            minimumCoverage: threshold
        )
        if verdict == .present, faceCount == 0 {
            Log.camera.info("no face but person in frame -> present (looking away from the camera)")
        } else if verdict == .absent, coverage > 0 {
            Log.camera.info("person coverage \(coverage, format: .fixed(precision: 3)) below threshold \(threshold, format: .fixed(precision: 3))")
        }
        return verdict
    }

    /// The pure presence decision, extracted so it is unit-testable without Vision.
    static func verdict(
        faceCount: Int,
        personCoverage: Double,
        mode: DetectionMode,
        minimumCoverage: Double
    ) -> Verdict {
        if faceCount > 0 { return .present }
        guard mode == .person else { return .absent }
        return personCoverage >= minimumCoverage ? .present : .absent
    }

    /// Fraction of mask pixels at >= 50% person confidence (OneComponent8 mask),
    /// subsampled for speed. Returns -1 if the buffer is unreadable.
    static func maskCoverage(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return -1 }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var hit = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if pixels[y * stride + x] >= 128 { hit += 1 }
                count += 1
                x += 4
            }
            y += 4
        }
        return count > 0 ? Double(hit) / Double(count) : -1
    }

    /// Subsampled mean of the luma plane. Returns nil for unexpected pixel formats,
    /// in which case the darkness guard is skipped (Vision still gets the frame).
    static func meanLuminance(of buffer: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard fullRange || videoRange else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                sum += Int(pixels[y * stride + x])
                count += 1
                x += 8
            }
            y += 8
        }
        guard count > 0 else { return nil }

        var mean = Double(sum) / Double(count) / 255.0
        if videoRange {
            // Video range luma spans 16–235; renormalize so "black" is ~0.
            mean = max(0, (mean - 16.0 / 255.0) * (255.0 / 219.0))
        }
        return mean
    }
}
