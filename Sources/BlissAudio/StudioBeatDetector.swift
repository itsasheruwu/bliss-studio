import Foundation

/// Tracks percussion from a stereo output tap in 10 ms hops, independent of the HAL buffer size.
/// All mutable state belongs to the IO queue. Only tempo and brief beat envelopes reach the UI.
struct StudioBeatDetector {
    struct Hit {
        let strength: Double
        let age: Double
    }

    private let grid = StudioBeatGrid()
    private var recentInterval = 0.0
    private var steadyIntervals = 0
    private var regularPeriod = 0.0
    private var regularUntil = 0.0
    private var sampleRate = 0.0
    private var bassLeft: Float = 0, bassRight: Float = 0
    private var bassSum = 0.0, wideSum = 0.0
    private var framesInHop = 0
    private var elapsed = 0.0
    private var lastBass = -90.0, lastWide = -90.0
    private var averageBass = -90.0, averageWide = -90.0
    private var averageFlux = 1.0
    private var lastOnset = -Double.infinity
    private var lastBeat = -Double.infinity
    private var confirmedAt = -Double.infinity
    private var nextBeat = Double.infinity
    private var period = 0.0
    private var candidatePeriod = 0.0
    private var candidateTime = -Double.infinity
    private var candidateVotes = 0

    var tempo: Double? { period > 0 ? 60 / period : nil }

    mutating func reset() {
        grid.reset()
        recentInterval = 0
        steadyIntervals = 0
        regularPeriod = 0
        regularUntil = 0
        sampleRate = 0
        bassLeft = 0; bassRight = 0
        bassSum = 0; wideSum = 0; framesInHop = 0; elapsed = 0
        lastBass = -90; lastWide = -90; averageBass = -90; averageWide = -90; averageFlux = 1
        lastOnset = -.infinity; lastBeat = -.infinity; confirmedAt = -.infinity
        period = 0; nextBeat = .infinity
        candidatePeriod = 0; candidateTime = -.infinity; candidateVotes = 0
    }

    /// The right lane can be interleaved with the left, in its own buffer, or equal to the left.
    mutating func consume(left: UnsafePointer<Float>, leftStride: Int, right: UnsafePointer<Float>,
                          rightStride: Int, frames: Int, rate: Double) -> Hit? {
        guard frames > 0, rate > 0 else { return nil }
        if rate != sampleRate { reset(); sampleRate = rate }
        let hop = max(1, Int((rate * 0.010).rounded()))
        let alpha = Float(1 - exp(-2 * .pi * 155 / rate))
        var hit: Hit?
        for index in 0..<frames {
            let l = left[index * leftStride], r = right[index * rightStride]
            let x = l.isFinite ? l : 0, y = r.isFinite ? r : 0
            grid.append(0.66 * x + 0.34 * y)
            bassLeft += alpha * (x - bassLeft)
            bassRight += alpha * (y - bassRight)
            bassSum += Double(bassLeft * bassLeft + bassRight * bassRight)
            wideSum += Double(x * x + y * y)
            framesInHop += 1
            if framesInHop == hop {
                let bass = 10 * log10(max(1e-9, bassSum / Double(2 * hop)))
                let wide = 10 * log10(max(1e-9, wideSum / Double(2 * hop)))
                let dt = Double(hop) / rate
                elapsed += dt
                if let strength = advance(bass: bass, wide: wide, dt: dt) {
                    hit = Hit(strength: strength, age: Double(frames - index - 1) / rate)
                }
                bassSum = 0; wideSum = 0; framesInHop = 0
            }
        }
        return hit
    }

    private mutating func advance(bass: Double, wide: Double, dt: Double) -> Double? {
        let bassJump = max(0, bass - lastBass), wideJump = max(0, wide - lastWide)
        // Bass attacks survive a loud, relatively steady vocal. Broadband attacks also admit snares
        // and claps on recordings with very little low end.
        let flux = max(0.88 * bassJump + 0.22 * wideJump, 0.82 * wideJump)
        let threshold = max(1.55, averageFlux * 1.7 + 0.7)
        let aboveBed = max(bass - averageBass, wide - averageWide) > 1.25
        lastBass = bass; lastWide = wide
        let blend = 1 - exp(-dt / 0.25)
        averageBass += (bass - averageBass) * blend
        averageWide += (wide - averageWide) * blend
        averageFlux += (min(15, flux) - averageFlux) * (1 - exp(-dt / 0.55))

        if let estimate = grid.analyze(rate: sampleRate, hop: dt, time: elapsed), wide > -75 {
            var candidate = estimate.period
            // A clean sequence of identical attacks resolves the half/double-time ambiguity.
            if elapsed < regularUntil {
                let ratio = candidate / regularPeriod
                if abs(ratio - 2) < 0.08 || abs(ratio - 1) < 0.05 { candidate = regularPeriod }
            }
            let newTempo = period == 0 || abs(candidate / period - 1) > 0.07
            if newTempo, confirmsTempo(candidate) {
                period = candidate
                let distance = (elapsed - estimate.previousBeat) / period
                nextBeat = estimate.previousBeat + (floor(distance) + 1) * period
                confirmedAt = elapsed
            } else if !newTempo {
                candidateVotes = 0
                period += 0.30 * (candidate - period)
                let sameBeat = estimate.previousBeat + ((nextBeat - estimate.previousBeat) / period).rounded() * period
                let error = sameBeat - nextBeat
                if abs(error) < 0.15 * period { nextBeat += 0.35 * error }
            }
        }
        if period > 0, grid.hasAttack, wide > -75 {
            let nearest = nextBeat + ((elapsed - nextBeat) / period).rounded() * period
            if abs(nearest - elapsed) < 0.050 { confirmedAt = elapsed }
        }
        if period > 0, elapsed - confirmedAt > min(2, 2.65 * period) {
            period = 0
            nextBeat = .infinity
        }

        var pulse: Double?
        if elapsed > 0.03, wide > -77, aboveBed, flux > threshold, elapsed - lastOnset >= 0.105 {
            let interval = elapsed - lastOnset
            if interval >= 0.30 && interval <= 1.14 {
                if abs(interval - recentInterval) < 0.026 {
                    steadyIntervals += 1
                    recentInterval += (interval - recentInterval) / Double(min(steadyIntervals, 8))
                } else {
                    steadyIntervals = 1
                    recentInterval = interval
                }
                if steadyIntervals >= 3 {
                    regularPeriod = recentInterval
                    regularUntil = elapsed + 5 * interval
                }
            } else { steadyIntervals = 0 }
            lastOnset = elapsed
            let strength = min(1, 0.35 + (flux - threshold) * 0.11 + min(0.22, bassJump * 0.035))
            pulse = observeOnset(strength)
        }
        if period > 0, elapsed >= nextBeat {
            nextBeat += period
            // Bridge a missing drum underneath audible music for one beat. A silent break stays dark.
            if pulse == nil, elapsed - confirmedAt <= period * 1.65, wide > -73, elapsed - lastBeat >= period * 0.56 {
                lastBeat = elapsed
                pulse = 0.64
            }
        }
        return pulse
    }

    /// A single syncopation can momentarily win the window at half or dotted time.
    /// Wait for agreement across overlapping windows before moving the beat grid.
    private mutating func confirmsTempo(_ candidate: Double) -> Bool {
        if candidateVotes > 0, elapsed - candidateTime < 0.85, abs(candidate / candidatePeriod - 1) < 0.045 {
            candidateVotes += 1
        } else {
            candidateVotes = 1
        }
        candidatePeriod = candidate
        candidateTime = elapsed
        return candidateVotes >= (period == 0 ? 2 : 3)
    }

    private mutating func observeOnset(_ strength: Double) -> Double? {
        if period == 0, steadyIntervals >= 3 {
            period = recentInterval
            nextBeat = elapsed + period
            confirmedAt = elapsed
        }
        if period > 0 {
            let expected = nextBeat + ((elapsed - nextBeat) / period).rounded() * period
            let error = elapsed - expected
            guard abs(error) <= min(0.055, period * 0.14) else { return nil }
            confirmedAt = elapsed
            nextBeat = expected + error * 0.16 + period
            if elapsed - lastBeat < period * 0.54 { return nil }
            lastBeat = elapsed
            return 0.72 + 0.28 * strength
        }
        // Render the observed attack while learning the tempo. Short subdivisions get one accent.
        guard elapsed - lastBeat >= 0.215 else { return nil }
        lastBeat = elapsed
        return 0.62 + 0.38 * strength
    }

}
