import Foundation

/// A tempo correction changes the travel speed without moving the existing highlights.
struct StudioRimMotion {
    static let beatsPerCycle = 16.0
    private static let ambientBPM = 96.0
    private(set) var phase = 0.75
    private var speed = ambientBPM / (60 * beatsPerCycle)
    private var previousTime: Double?
    private var beatLead = 0.0

    static func validTempo(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (30...300).contains(value) else { return nil }
        return value
    }

    /// The timeline can go completely idle while the switch is off.
    mutating func pause() {
        previousTime = nil
        beatLead = 0
    }

    mutating func sample(at time: Double, tempo: Double?, moving: Bool, beat: Double = 0) -> Double {
        guard time.isFinite else { return phase }
        guard moving else {
            pause()
            return phase
        }
        let target = (Self.validTempo(tempo) ?? Self.ambientBPM) / (60 * Self.beatsPerCycle)
        guard let previous = previousTime else {
            previousTime = time
            speed = target
            return phase
        }
        guard time > previous else { return phase }
        previousTime = time
        let elapsed = time - previous
        // Allow the slower timeline cadence of a background panel. Re-anchor after
        // an actual display sleep rather than replaying minutes of missed travel.
        guard elapsed < 4 else {
            speed = target
            beatLead = 0
            return phase
        }
        let response = 0.52
        let drift = speed - target
        let blend = -expm1(-elapsed / response)
        let travel = target * elapsed + drift * response * blend
        speed -= drift * blend

        // Borrow a fraction of a beat on the attack, then give that distance back
        // between hits. Even a sudden loss of audio must leave the band moving right.
        let strength = beat.isFinite ? min(1, max(0, beat)) : 0
        let targetLead = strength * 0.18 / Self.beatsPerCycle
        let responseTime = targetLead > beatLead ? 0.055 : 0.15
        let adjustment = (targetLead - beatLead) * -expm1(-elapsed / responseTime)
        let step = min(1.6 * travel, max(-0.55 * travel, adjustment))
        beatLead += step
        phase = (phase + travel + step).truncatingRemainder(dividingBy: 1)
        return phase
    }
    /// Conic gradient stops are angular, but the light travels equal distances along
    /// the physical perimeter on wide and tall displays alike. Zero is the right midpoint.
    static func gradientLocation(at fraction: Double, in size: CGSize) -> Double {
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return 1 }
        let w = size.width / 2, h = size.height / 2
        let distance = fraction * 4 * (w + h)
        let x: Double, y: Double
        if distance < h { x = w; y = distance }
        else if distance < h + 2 * w { x = w - (distance - h); y = h }
        else if distance < 3 * h + 2 * w { x = -w; y = h - (distance - h - 2 * w) }
        else if distance < 3 * h + 4 * w { x = -w + (distance - 3 * h - 2 * w); y = -h }
        else { x = w; y = -h + (distance - 3 * h - 4 * w) }
        let angle = atan2(y, x) / (2 * .pi)
        return angle < 0 ? angle + 1 : angle
    }
}
