import Accelerate
import Foundation

/// Estimates tempo and phase from a rolling history of whitened spectral flux. A snare can
/// change many frequency bins even when a sustained vocal masks the change in overall level.
/// Storage and the FFT plan are allocated once, ahead of the HAL callback.
final class StudioBeatGrid {
    struct Estimate {
        let period: Double
        let previousBeat: Double
    }
    private static let length = 1024
    private static let history = 650
    private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: length)
    private var samples = [Float](repeating: 0, count: 2 * length)
    private var real = [Float](repeating: 0, count: length)
    private var imag = [Float](repeating: 0, count: length)
    private var magnitude = [Float](repeating: 0, count: length / 2)
    private var previous = [Float](repeating: 0, count: length / 2)
    private var baseline = [Float](repeating: 0, count: length / 2)
    private var flux = [Float](repeating: 0, count: 2 * history)
    private var accents = [Float](repeating: 0, count: 2 * history)
    private var correlation = [Float](repeating: 0, count: history)
    private var write = 0
    private var count = 0
    private var head = 0
    private var average: Float = 0
    private var countdown = 0
    private(set) var hasAttack = false

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.length), Int32(vDSP_HANN_DENORM))
    }

    deinit { if let fft { vDSP_destroy_fftsetup(fft) } }

    func reset() {
        write = 0; head = 0; count = 0; average = 0; countdown = 0; hasAttack = false
        samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        baseline.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        previous.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    func append(_ sample: Float) {
        samples[write] = sample
        samples[write + Self.length] = sample
        write = (write + 1) & (Self.length - 1)
    }

    func analyze(rate: Double, hop: Double, time: Double) -> Estimate? {
        guard let fft else { return nil }
        samples.withUnsafeBufferPointer { input in
            vDSP_vmul(input.baseAddress! + write, 1, window, 1, &real, 1, vDSP_Length(Self.length))
        }
        vDSP_vclr(&imag, 1, vDSP_Length(Self.length))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(Self.length / 2))
            }
        }
        let bassEnd = min(magnitude.count, max(2, Int(220 * Double(Self.length) / rate) + 1))
        let midEnd = min(magnitude.count, max(bassEnd, Int(3200 * Double(Self.length) / rate) + 1))
        let highEnd = min(magnitude.count, max(midEnd, Int(14000 * Double(Self.length) / rate) + 1))
        var bass: Float = 0, mid: Float = 0, high: Float = 0
        for i in 1..<highEnd {
            let m = magnitude[i]
            let normalized = log1pf(m / (baseline[i] + 0.0256))
            let change = max(0, normalized - previous[i])
            previous[i] = normalized
            baseline[i] += 0.009 * (m - baseline[i])
            if i < bassEnd { bass += change }
            else if i < midEnd { mid += change }
            else { high += change }
        }
        bass /= Float(bassEnd - 1)
        mid /= Float(max(1, midEnd - bassEnd))
        high /= Float(max(1, highEnd - midEnd))
        let value = 0.18 * bass + 0.54 * mid + 0.28 * high
        let centered = value - average
        average += 0.075 * centered
        hasAttack = value > max(0.016, average * 1.5)
        flux[head] = centered; flux[head + Self.history] = centered
        let accent = 0.45 * bass + 0.26 * mid + 0.29 * high
        accents[head] = accent; accents[head + Self.history] = accent
        head = (head + 1) % Self.history
        count = min(count + 1, Self.history)
        guard count >= 210 else { return nil }
        countdown -= 1
        guard countdown <= 0 else { return nil }
        countdown = 39
        return estimate(hop: hop, time: time)
    }

    private func estimate(hop: Double, time: Double) -> Estimate? {
        // The mirrored ring makes the two overlapping windows contiguous at every lag.
        let begin = head + Self.history - count
        let limit = min(correlation.count - 1, count - 75)
        flux.withUnsafeBufferPointer { values in
            let first = values.baseAddress! + begin
            for lag in 29...limit {
                let n = vDSP_Length(count - lag)
                let second = first + lag
                var product: Float = 0, a: Float = 0, b: Float = 0
                vDSP_dotpr(first, 1, second, 1, &product, n)
                vDSP_svesq(first, 1, &a, n)
                vDSP_svesq(second, 1, &b, n)
                correlation[lag] = product / sqrt(max(1e-9, a * b))
            }
        }
        var bestLag = 0
        var bestScore: Float = 0
        var barLag = 0
        var barScore: Float = 0
        for lag in 30...112 where count >= lag * 3 {
            var score = correlation[lag]
            // Repeated accent patterns reinforce the fundamental and suppress isolated attacks.
            for harmonic in 2...3 {
                let peak = lag * harmonic
                if peak + 1 <= limit {
                    let resonance = max(0, correlation[peak - 1], correlation[peak], correlation[peak + 1])
                    score += resonance * (harmonic == 2 ? 0.50 : 0.25)
                }
            }
            let preference = max(0.70, 1 - 0.40 * abs(log2f(Float(lag) / 58)))
            score *= preference
            if score > bestScore { bestScore = score; bestLag = lag }
            // Syncopated recordings can have weak consecutive kicks while repeating an
            // entire drum pattern across bars. Allow small integer-hop rounding errors.
            guard correlation[lag] > 0.065, 4 * lag + 2 <= limit else { continue }
            let bar = 4 * lag
            let oneBar = correlation[(bar - 2)...(bar + 2)].max() ?? 0
            var patternScore = score + preference * 0.65 * max(0, oneBar)
            let twoBars = 8 * lag
            if twoBars + 3 <= limit {
                let repeated = correlation[(twoBars - 3)...(twoBars + 3)].max() ?? 0
                patternScore += preference * 0.45 * max(0, repeated)
            }
            if patternScore > barScore { barScore = patternScore; barLag = lag }
        }
        if bestLag == 0 || bestScore < 0.38 || correlation[bestLag] <= 0.17 {
            guard barScore >= 0.45 else { return nil }
            bestLag = barLag
        }
        let left = correlation[bestLag - 1], center = correlation[bestLag], right = correlation[bestLag + 1]
        let curvature = left - 2 * center + right
        let offset = curvature < -0.0001 ? min(0.5, max(-0.5, 0.5 * (left - right) / curvature)) : 0
        let lag = Double(bestLag) + Double(offset)

        // Fold the strongest attacks over several periods to locate the actual drum phase.
        let end = head + Self.history - 1
        var peak: Float = 0, ageOfBeat = 0
        for age in 0..<bestLag {
            var weight: Float = 1, evidence: Float = 0
            for beat in 0..<8 {
                let index = end - age - Int((Double(beat) * lag).rounded())
                if index - 1 < begin || index + 1 > end { continue }
                evidence += weight * (accents[index] + 0.5 * (accents[index - 1] + accents[index + 1]))
                weight *= 0.92
            }
            if evidence > peak { peak = evidence; ageOfBeat = age }
        }
        return Estimate(period: lag * hop, previousBeat: time - Double(ageOfBeat) * hop)
    }
}
