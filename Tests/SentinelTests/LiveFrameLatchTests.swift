import CoreVideo
import Foundation
import Testing
@testable import Sentinel

private func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

@Test func aFrameFromBeforeTheRequestIsNeverServed() {
    let latch = LiveFrameLatch()
    latch.ingest(makeBuffer())
    #expect(latch.nextFrame(warmupFrames: 0, timeout: 0.05) == nil)
}

@Test func warmupFramesDoNotSatisfyARequest() async {
    let latch = LiveFrameLatch()
    latch.ingest(makeBuffer())
    latch.ingest(makeBuffer())
    let request = Task.detached { latch.nextFrame(warmupFrames: 3, timeout: 0.2) != nil }
    try? await Task.sleep(for: .milliseconds(20))
    latch.ingest(makeBuffer()) // third frame: still within warmup, must not satisfy
    #expect(await request.value == false)
}

@Test func postWarmupRequestReturnsTheNextLiveFrame() async {
    let latch = LiveFrameLatch()
    for _ in 0..<3 { latch.ingest(makeBuffer()) } // session already warm
    let request = Task.detached { latch.nextFrame(warmupFrames: 3, timeout: 2.0) != nil }
    let feeder = Task.detached {
        while !Task.isCancelled {
            latch.ingest(makeBuffer())
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    #expect(await request.value == true)
    feeder.cancel()
}

@Test func timeoutReturnsNilAndRetainsNothingForTheNextRequest() {
    let latch = LiveFrameLatch()
    #expect(latch.nextFrame(warmupFrames: 0, timeout: 0.05) == nil)
    latch.ingest(makeBuffer()) // arrives after the timeout, with no pending request
    #expect(latch.nextFrame(warmupFrames: 0, timeout: 0.05) == nil)
}
