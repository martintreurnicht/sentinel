import CoreVideo
import Vision

/// Decides face / no face / too-dark for a captured frame.
///
/// The luminance guard exists so a covered lens, a clamshell lid, or a camera staring
/// into darkness reads as "inconclusive" rather than "absent" — absence may lock the
/// screen, so it must only ever come from a well-lit frame with no detectable face.
struct FaceDetector: Sendable {
    enum Verdict: Sendable {
        case face
        case noFace
        case tooDark
    }

    /// Mean luma (0...1, full range) below which a frame is considered unjudgeable.
    var darknessThreshold: Double = 0.05

    func analyze(_ frame: CameraService.Frame) throws -> Verdict {
        if let luminance = Self.meanLuminance(of: frame.pixelBuffer), luminance < darknessThreshold {
            Log.camera.info("frame too dark (mean luma \(luminance, format: .fixed(precision: 3)))")
            return .tooDark
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        try handler.perform([request])
        let faceCount = request.results?.count ?? 0
        Log.camera.info("face detection found \(faceCount) face(s)")
        return faceCount > 0 ? .face : .noFace
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
