import Foundation

/// A sticker pose relative to its resting anchor on the message. Distances are in
/// points, positive y is down, and pitch rotates around the vertical axis.
nonisolated struct StudioStickerPlacement: Equatable, Sendable {
    let dx: Double
    let dy: Double
    let scaleX: Double
    let scaleY: Double
    let rotationDegrees: Double
    let pitchDegrees: Double
    let shadowRadius: Double
    let shadowY: Double
    let shadowOpacity: Double
    let glintAlpha: Double

    static func sample(age: Double, messageRight: Bool, compact: Bool, reduceMotion: Bool) -> Self {
        let duration = 0.75
        let time = age.isFinite && !reduceMotion ? max(0, age) : duration
        let side = messageRight ? -1.0 : 1.0
        let pickup = smooth(time / 0.100)
        let drag = smooth((time - 0.065) / 0.270)
        let arc = 4 * drag * (1 - drag)

        // Hold the enlarged sticker over its destination before releasing it.
        // Position and size stay steady through the short hover at 335–415 ms.
        let held = 1 - smooth((time - 0.415) / 0.116)
        let flightX = (compact ? 38.0 : 60.0) * (1 - drag) + 2.6 * drag + 3.2 * arc
        let flightY = (compact ? 26.0 : 39.0) * (1 - drag) - 2.1 * drag - 5.5 * arc

        // The bubble-facing corner lands first. The raised outer edge continues
        // to unroll while the contact patch briefly broadens under pressure.
        let curl = 1 - smooth((time - 0.422) / 0.134)
        let pressure: Double
        if time < 0.535 {
            pressure = smooth((time - 0.456) / 0.079)
        } else if time < duration {
            let release = (time - 0.535) / (duration - 0.535)
            let decay = 7 * release
            // Critical damping returns from peak compression without rebounding.
            pressure = (1 + decay) * exp(-decay) * (1 - smooth((release - 0.75) / 0.25))
        } else {
            pressure = 0
        }

        return Self(
            dx: side * (flightX * held - 1.25 * pressure),
            dy: flightY * held + 1.1 * pressure,
            scaleX: 1 + (0.11 + 0.14 * pickup) * held + 0.038 * pressure,
            scaleY: 1 + (0.10 + 0.145 * pickup) * held - 0.050 * pressure,
            rotationDegrees: side * (8 + (12 - 8 * drag + 2.4 * arc) * held - 1.9 * pressure),
            pitchDegrees: side * ((24 + 5 * pickup - 17 * drag + 2 * arc) * curl - 1.5 * pressure),
            shadowRadius: 2 + (3.6 + 2 * pickup - 2.5 * drag) * held - 1.05 * pressure,
            shadowY: 2 + (5 + 2 * pickup - 3 * drag) * held - 1.1 * pressure,
            shadowOpacity: 0.45 - 0.19 * held + 0.085 * pressure,
            glintAlpha: (0.12 + 0.05 * pickup + 0.04 * arc - 0.08 * drag) * curl + 0.14 * pressure
        )
    }

    private static func smooth(_ position: Double) -> Double {
        let t = min(1, max(0, position))
        return t * t * (3 - 2 * t)
    }
}
