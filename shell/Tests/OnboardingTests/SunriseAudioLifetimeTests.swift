import AVFoundation
@testable import Onboarding
import XCTest

/// rc-tests 1377: the render thread called into a released score through an
/// unowned reference and trapped. The score now plays silence once it is gone,
/// and stops and detaches its engine before it goes.
final class SunriseAudioLifetimeTests: XCTestCase {
    /// Two channels of `frames` floats, filled with `value`.
    private func buffers(frames: Int, value: Float) -> (UnsafeMutableAudioBufferListPointer, [UnsafeMutablePointer<Float>]) {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        var channels: [UnsafeMutablePointer<Float>] = []
        for i in 0..<2 {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            data.initialize(repeating: value, count: frames)
            channels.append(data)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: data)
        }
        return (list, channels)
    }

    private func call(_ block: AVAudioSourceNodeRenderBlock, frames: Int) -> [[Float]] {
        let (list, channels) = buffers(frames: frames, value: 1)
        defer {
            channels.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        var silence = ObjCBool(false)
        var stamp = AudioTimeStamp()
        XCTAssertEqual(block(&silence, &stamp, AVAudioFrameCount(frames), list.unsafeMutablePointer), noErr)
        return channels.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    func testTheRenderBlockPlaysSilenceWithNoOwner() {
        let out = call(SunriseAudio.renderBlock { nil }, frames: 512)
        XCTAssertTrue(out.allSatisfy { $0.allSatisfy { $0 == 0 } }, "silence, not what was in the buffer")
    }

    func testTheRenderBlockRunsAfterThePlayingScoreIsReleased() throws {
        var audio: SunriseAudio? = try SunriseAudio(variant: .horizon, offline: true)
        let engine = try XCTUnwrap(audio).engine
        try engine.start()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        // Past the opening silence, so the score really plays.
        audio?.synth.seek(to: 4)
        XCTAssertEqual(try engine.renderOffline(4096, to: buffer), .success)
        // The same block the node holds, kept past the score's release.
        let block = SunriseAudio.renderBlock { [weak audio] in audio?.synth }
        XCTAssertFalse(call(block, frames: 256).allSatisfy { $0.allSatisfy { $0 == 0 } }, "the score plays while it lives")
        audio = nil
        XCTAssertFalse(engine.isRunning, "released means stopped")
        XCTAssertFalse(engine.attachedNodes.contains { $0 is AVAudioSourceNode }, "and the score's nodes detached")
        let out = call(block, frames: 256)
        XCTAssertTrue(out.allSatisfy { $0.allSatisfy { $0 == 0 } }, "a late render call plays silence")
    }

    func testCloseStopsAndDetachesAndCanRunTwice() throws {
        let audio = try SunriseAudio(variant: .horizon, offline: true)
        try audio.engine.start()
        audio.close()
        XCTAssertFalse(audio.engine.isRunning)
        XCTAssertFalse(audio.engine.attachedNodes.contains { $0 is AVAudioSourceNode || $0 is AVAudioPlayerNode })
        audio.close()
    }

    @MainActor
    func testThePlayerLetsItsScoreGoWhenTheSceneCloses() throws {
        let player = SunrisePlayer(variant: .horizon, reduced: true)
        weak var audio = player.audio
        let engine = try XCTUnwrap(audio).engine
        player.closeAudio()
        XCTAssertNil(player.audio)
        XCTAssertNil(audio, "released on the main thread, not on the render thread's last call")
        XCTAssertFalse(engine.isRunning)
    }
}
