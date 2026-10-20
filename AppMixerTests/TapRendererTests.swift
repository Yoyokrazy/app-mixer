import AudioToolbox
import Testing

@Suite("TapRenderer")
struct TapRendererTests {
    /// A stereo tap whose left channel counts up 1, 2, 3, ... and right channel counts down -1, -2, -3, ...
    static func stereoTap(frames: Int = 8) -> (TestBufferList, left: [Float], right: [Float]) {
        let left = (1...frames).map(Float.init)
        let right = left.map { -$0 }
        let tap = TestBufferList(channels: 2, frames: frames)
        tap.setSamples(interleave(left, right))
        return (tap, left, right)
    }

    static func renderer(gain: Float = 1, ramp: Float = 0.5, left: Int = 0, right: Int = 1) -> TapRenderer {
        TapRenderer(gain: gain, rampCoefficient: ramp, left: left, right: right)
    }

    // MARK: - Gain

    @Test func unityGainCopiesTapToOutput() {
        let (tap, left, right) = Self.stereoTap()
        let output = TestBufferList(channels: 2, frames: 8, fill: 99)

        Self.renderer().render(input: tap, output: output)

        #expect(output.channel(0) == left)
        #expect(output.channel(1) == right)
    }

    @Test(arguments: [Float(0), 0.25, 0.5])
    func steadyGainScalesEverySample(gain: Float) {
        let (tap, left, right) = Self.stereoTap()
        let output = TestBufferList(channels: 2, frames: 8)

        Self.renderer(gain: gain).render(input: tap, output: output)

        #expect(output.channel(0) == left.map { $0 * gain })
        #expect(output.channel(1) == right.map { $0 * gain })
    }

    @Test func targetGainStartsAtInitialGainAndIsSettable() {
        let renderer = Self.renderer(gain: 0.3)
        #expect(renderer.targetGain == 0.3)
        renderer.targetGain = 0.7
        #expect(renderer.targetGain == 0.7)
    }

    // MARK: - Ramp

    @Test func gainChangeRampsWithoutJumping() {
        let ramp: Float = 0.01
        let renderer = Self.renderer(gain: 1, ramp: ramp)
        let tap = TestBufferList(channels: 2, frames: 64, fill: 1)
        let output = TestBufferList(channels: 2, frames: 64)

        renderer.targetGain = 0
        renderer.render(input: tap, output: output)
        let samples = output.channel(0)

        // First sample has already taken one ramp step; no sample jumps by more than one step.
        #expect(abs(samples[0] - (1 - ramp)) < 1e-6)
        for (previous, next) in zip(samples, samples.dropFirst()) {
            #expect(next < previous)
            #expect(previous - next <= ramp + 1e-6)
        }
        #expect(samples.allSatisfy { $0 > 0 && $0 < 1 })
        #expect(output.channel(1) == samples)
    }

    @Test func rampUpIsMonotonic() {
        let renderer = Self.renderer(gain: 0, ramp: 0.05)
        let tap = TestBufferList(channels: 2, frames: 128, fill: 1)
        let output = TestBufferList(channels: 2, frames: 128)

        renderer.targetGain = 1
        renderer.render(input: tap, output: output)
        let samples = output.channel(0)

        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
        #expect(samples.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func rampContinuesAcrossBuffers() {
        let ramp: Float = 0.01
        let renderer = Self.renderer(gain: 1, ramp: ramp)
        let tap = TestBufferList(channels: 2, frames: 32, fill: 1)
        let first = TestBufferList(channels: 2, frames: 32)
        let second = TestBufferList(channels: 2, frames: 32)

        renderer.targetGain = 0
        renderer.render(input: tap, output: first)
        renderer.render(input: tap, output: second)

        let end = first.channel(0).last!
        let start = second.channel(0).first!
        #expect(start < end)
        #expect(end - start <= ramp)
    }

    @Test func rampSettlesExactlyOnTarget() {
        let renderer = Self.renderer(gain: 1, ramp: 0.5)
        let (tap, left, _) = Self.stereoTap(frames: 64)
        let output = TestBufferList(channels: 2, frames: 64)

        renderer.targetGain = 0.3
        renderer.render(input: tap, output: output)
        renderer.render(input: tap, output: output)

        #expect(output.channel(0) == left.map { $0 * 0.3 })
    }

    @Test func rampCoefficientGivesAThirtyMillisecondTimeConstant() {
        let sampleRate: Float = 48_000
        let coefficient = TapRenderer.rampCoefficient(sampleRate: sampleRate)
        #expect(abs(coefficient - (1 - exp(-1 / 1_440))) < 1e-9)

        // After one time constant (30 ms) a one-pole ramp has covered 1 - 1/e ≈ 63% of the way.
        let frames = Int(sampleRate * 0.03)
        let renderer = Self.renderer(gain: 0, ramp: coefficient)
        let tap = TestBufferList(channels: 2, frames: frames, fill: 1)
        let output = TestBufferList(channels: 2, frames: frames)
        renderer.targetGain = 1
        renderer.render(input: tap, output: output)
        #expect(abs(output.channel(0).last! - (1 - exp(-1))) < 0.002)
    }

    @Test func rampCoefficientScalesWithSampleRate() {
        let slow = TapRenderer.rampCoefficient(sampleRate: 96_000)
        let fast = TapRenderer.rampCoefficient(sampleRate: 44_100)
        #expect(slow < fast)
        #expect(slow > 0 && fast < 1)
        #expect(TapRenderer.rampCoefficient(sampleRate: 48_000, timeConstant: 0.01) > TapRenderer.rampCoefficient(sampleRate: 48_000))
    }

    // MARK: - Input selection

    @Test func readsTheTrailingInputStreamAsTheTap() {
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [5, 6, 7, 8]
        let input = TestBufferList([
            .init(channels: 1, frames: 4, fill: 42), // a headset mic that's part of the aggregate
            .init(channels: 2, frames: 4),
        ])
        input.setSamples(interleave(left, right), stream: 1)
        let output = TestBufferList(channels: 2, frames: 4)

        Self.renderer().render(input: input, output: output)

        #expect(output.channel(0) == left)
        #expect(output.channel(1) == right)
    }

    @Test func monoTapFeedsBothOutputChannels() {
        let input = TestBufferList(channels: 1, frames: 4)
        input.setSamples([1, 2, 3, 4])
        let output = TestBufferList(channels: 2, frames: 4)

        Self.renderer(gain: 0.5).render(input: input, output: output)

        #expect(output.channel(0) == [0.5, 1, 1.5, 2])
        #expect(output.channel(1) == [0.5, 1, 1.5, 2])
    }

    @Test func zeroChannelTapIsTreatedAsMono() {
        let input = TestBufferList(channels: 0, frames: 3)
        input.setSamples([1, 2, 3])
        let output = TestBufferList(channels: 2, frames: 3)

        Self.renderer().render(input: input, output: output)

        #expect(output.channel(0) == [1, 2, 3])
        #expect(output.channel(1) == [1, 2, 3])
    }

    // MARK: - Silence

    @Test func noInputStreamsProducesSilence() {
        let input = TestBufferList([])
        let output = TestBufferList(channels: 2, frames: 8, fill: 99)

        Self.renderer().render(input: input, output: output)

        #expect(output.samples().allSatisfy { $0 == 0 })
    }

    @Test func tapWithoutDataProducesSilence() {
        let input = TestBufferList([.init(channels: 2, frames: 8, hasData: false)])
        let output = TestBufferList([.init(channels: 2, frames: 8, fill: 99), .init(channels: 2, frames: 8, fill: 99)])

        Self.renderer().render(input: input, output: output)

        #expect(output.samples(stream: 0).allSatisfy { $0 == 0 })
        #expect(output.samples(stream: 1).allSatisfy { $0 == 0 })
    }

    @Test func outputWithoutAnyDataIsLeftAlone() {
        let (tap, _, _) = Self.stereoTap()
        let output = TestBufferList([.init(channels: 2, frames: 8, hasData: false)])

        Self.renderer().render(input: tap, output: output) // must not crash
    }

    @Test func clearsUnusedOutputChannels() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList(channels: 4, frames: 4, fill: 99)

        Self.renderer().render(input: tap, output: output)

        #expect(output.channel(0) == left)
        #expect(output.channel(1) == right)
        #expect(output.channel(2) == [0, 0, 0, 0])
        #expect(output.channel(3) == [0, 0, 0, 0])
    }

    // MARK: - Output channel mapping

    @Test func usesThePreferredStereoPairWithinAStream() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList(channels: 4, frames: 4, fill: 99)

        Self.renderer(left: 2, right: 3).render(input: tap, output: output)

        #expect(output.channel(0) == [0, 0, 0, 0])
        #expect(output.channel(1) == [0, 0, 0, 0])
        #expect(output.channel(2) == left)
        #expect(output.channel(3) == right)
    }

    @Test func preferredPairCanSpanTwoStreams() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList([.init(channels: 2, frames: 4, fill: 99), .init(channels: 2, frames: 4, fill: 99)])

        // Channels 0-1 live in the first stream, 2-3 in the second.
        Self.renderer(left: 1, right: 2).render(input: tap, output: output)

        #expect(output.channel(0, stream: 0) == [0, 0, 0, 0])
        #expect(output.channel(1, stream: 0) == left)
        #expect(output.channel(0, stream: 1) == right)
        #expect(output.channel(1, stream: 1) == [0, 0, 0, 0])
    }

    @Test func preferredPairInALaterStream() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList([.init(channels: 2, frames: 4), .init(channels: 2, frames: 4)])

        Self.renderer(left: 2, right: 3).render(input: tap, output: output)

        #expect(output.samples(stream: 0).allSatisfy { $0 == 0 })
        #expect(output.channel(0, stream: 1) == left)
        #expect(output.channel(1, stream: 1) == right)
    }

    @Test func streamsWithoutDataStillCountTowardChannelNumbers() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList([.init(channels: 2, frames: 4, hasData: false), .init(channels: 2, frames: 4)])

        Self.renderer(left: 2, right: 3).render(input: tap, output: output)

        #expect(output.channel(0, stream: 1) == left)
        #expect(output.channel(1, stream: 1) == right)
    }

    @Test func outOfRangePairFallsBackToTheFirstTwoChannels() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList(channels: 2, frames: 4, fill: 99)

        Self.renderer(left: 6, right: 7).render(input: tap, output: output)

        #expect(output.channel(0) == left)
        #expect(output.channel(1) == right)
    }

    @Test func outOfRangePairOnAMonoDeviceDownmixes() {
        let input = TestBufferList(channels: 2, frames: 3)
        input.setSamples(interleave([1, 2, 3], [3, 4, 5]))
        let output = TestBufferList(channels: 1, frames: 3, fill: 99)

        Self.renderer(left: 4, right: 5).render(input: input, output: output)

        #expect(output.samples() == [2, 3, 4])
    }

    @Test func monoOutputDownmixesStereo() {
        let input = TestBufferList(channels: 2, frames: 3)
        input.setSamples(interleave([1, 2, 3], [3, 4, 5]))
        let output = TestBufferList(channels: 1, frames: 3)

        Self.renderer(gain: 0.5).render(input: input, output: output)

        #expect(output.samples() == [1, 1.5, 2])
    }

    @Test func missingRightChannelDownmixesIntoLeft() {
        let input = TestBufferList(channels: 2, frames: 3)
        input.setSamples(interleave([1, 2, 3], [3, 4, 5]))
        let output = TestBufferList(channels: 2, frames: 3, fill: 99)

        Self.renderer(left: 0, right: 9).render(input: input, output: output)

        #expect(output.channel(0) == [2, 3, 4])
        #expect(output.channel(1) == [0, 0, 0])
    }

    // MARK: - Frame counts

    @Test func neverWritesPastTheShortestOutputStream() {
        let (tap, left, right) = Self.stereoTap(frames: 8)
        let output = TestBufferList([
            .init(channels: 2, frames: 8, guardSamples: 4),
            .init(channels: 2, frames: 4, guardSamples: 4),
        ])

        Self.renderer(left: 0, right: 2).render(input: tap, output: output)

        #expect(output.channel(0, stream: 0) == Array(left.prefix(4)) + [0, 0, 0, 0])
        #expect(output.channel(0, stream: 1) == Array(right.prefix(4)))
        #expect(output.guardSamplesIntact(stream: 0))
        #expect(output.guardSamplesIntact(stream: 1))
    }

    @Test func shortTapLeavesTheRestOfTheOutputSilent() {
        let (tap, left, right) = Self.stereoTap(frames: 4)
        let output = TestBufferList([.init(channels: 2, frames: 8, fill: 99, guardSamples: 4)])

        Self.renderer().render(input: tap, output: output)

        #expect(output.channel(0) == left + [0, 0, 0, 0])
        #expect(output.channel(1) == right + [0, 0, 0, 0])
        #expect(output.guardSamplesIntact())
    }

    @Test func longTapIsTruncatedToTheOutput() {
        let (tap, left, right) = Self.stereoTap(frames: 16)
        let output = TestBufferList([.init(channels: 2, frames: 4, guardSamples: 8)])

        Self.renderer().render(input: tap, output: output)

        #expect(output.channel(0) == Array(left.prefix(4)))
        #expect(output.channel(1) == Array(right.prefix(4)))
        #expect(output.guardSamplesIntact())
    }
}
