import Accelerate
import AudioToolbox
import Foundation
import Synchronization

/// A private, input-only aggregate. The tap follows the system output mix while
/// the existing player continues to drive its own audio device.
package actor StudioMeter {
    private var resources = TapResources()
    private let envelope = StudioEnvelope()
    private let rhythm = StudioBeatCapture()
    private let queue = DispatchQueue(label: "com.itsasheruwu.bliss-studio-meter", qos: .userInitiated)

    package init() {}
    package nonisolated var level: Double { envelope.level }
    package nonisolated var pulse: Double { envelope.pulse }
    package nonisolated var beat: Double { rhythm.beat }
    package nonisolated var tempo: Double? { rhythm.tempo }
    package nonisolated func followBeats(_ enabled: Bool) { rhythm.setEnabled(enabled) }
    package nonisolated func resetBeat() { rhythm.invalidate() }

    package func start() throws {
        guard !resources.isActive else { return }
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.name = "Bliss Studio"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        resources.tapDescription = tap

        do {
            try check(AudioHardwareCreateProcessTap(tap, &resources.tapID))
            let format = try resources.tapID.readAudioTapStreamBasicDescription()
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw MeterError.unsupportedFormat
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Bliss Studio",
                kAudioAggregateDeviceUIDKey: "com.itsasheruwu.bliss-studio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &resources.aggregateDeviceID))
            // HAL owns the callback thread. Capture only the atomic envelope and
            // immutable sample rate. Never retain the actor or hand buffers to UI.
            let envelope = envelope
            let rhythm = rhythm
            let sampleRate = format.mSampleRate
            try check(AudioDeviceCreateIOProcIDWithBlock(&resources.deviceProcID, resources.aggregateDeviceID, queue) {
                _, input, _, _, _ in
                envelope.consume(input, sampleRate: sampleRate)
                rhythm.consume(input, sampleRate: sampleRate)
            })
            try check(AudioDeviceStart(resources.aggregateDeviceID, resources.deviceProcID))
        } catch {
            stop()
            throw error
        }
    }

    package func stop() {
        resources.destroy()
        envelope.reset()
        rhythm.invalidate()
    }

    deinit { resources.destroy() }

    private func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        throw MeterError.coreAudio(status)
    }

    private enum MeterError: LocalizedError {
        case coreAudio(OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let code) where code == kAudioDevicePermissionsError || code == kAudioQueueErr_Permissions:
                "Allow Bliss Studio system audio recording in System Settings → Privacy & Security to use reactive light."
            case .coreAudio(let code):
                "Core Audio couldn’t start reactive light (\(code))."
            case .unsupportedFormat:
                "This output’s audio format doesn’t support reactive light."
            }
        }
    }
}

/// One HAL writer and any number of visual readers. The callback only reduces
/// the current float buffers and publishes an envelope and its timestamp.
final class StudioEnvelope: Sendable {
    private let value = Atomic<UInt32>(0)
    private let accent = Atomic<UInt32>(0)
    // The callback is the sole writer until the device has stopped. Keep the
    // reference in dB so the same drum attack registers at low player volumes.
    private let referenceDB = Atomic<UInt32>(Float(-80).bitPattern)
    private let lastSample = Atomic<UInt64>(0)
    private let clockFrequency = AudioGetHostClockFrequency()

    var level: Double { displayed(value.load(ordering: .relaxed)) }
    var pulse: Double { displayed(accent.load(ordering: .relaxed)) }

    private func displayed(_ bits: UInt32) -> Double {
        let stamp = lastSample.load(ordering: .acquiring)
        guard stamp > 0 else { return 0 }
        let measured = Double(Float(bitPattern: bits))
        let now = AudioGetCurrentHostTime()
        let age = now > stamp ? Double(now - stamp) / clockFrequency : 0
        // Some output devices stop delivering callbacks entirely while silent.
        return age < 0.1 ? measured : measured * exp(-(age - 0.1) / 0.12)
    }

    func reset() {
        value.store(0, ordering: .relaxed)
        accent.store(0, ordering: .relaxed)
        referenceDB.store(Float(-80).bitPattern, ordering: .relaxed)
        lastSample.store(0, ordering: .releasing)
    }

    func consume(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var sum: Float = 0
        var sampleCount = 0
        var frameCount = 0
        for buffer in buffers {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0, let bytes = buffer.mData else { continue }
            var squares: Float = 0
            vDSP_svesq(bytes.assumingMemoryBound(to: Float.self), 1, &squares, vDSP_Length(count))
            sum += squares
            sampleCount += count
            frameCount = max(frameCount, count / max(1, Int(buffer.mNumberChannels)))
        }
        guard sampleCount > 0, sampleRate > 0 else { return }
        let rms = sqrt(Double(sum) / Double(sampleCount))
        let db = rms.isFinite ? max(-80, min(0, 20 * log10(max(0.0001, rms)))) : -80
        let duration = Double(frameCount) / sampleRate
        let now = AudioGetCurrentHostTime()
        let last = lastSample.load(ordering: .relaxed)
        let resumed = last == 0 || (now > last && Double(now - last) / clockFrequency > 0.6)
        let previous = resumed ? 0 : Double(Float(bitPattern: value.load(ordering: .relaxed)))
        let target = min(1, max(0, (db + 65) / 62))
        let blend = 1 - exp(-duration / (target > previous ? 0.035 : 0.17))
        value.store(Float(previous + (target - previous) * blend).bitPattern, ordering: .relaxed)

        let reference = resumed ? db : Double(Float(bitPattern: referenceDB.load(ordering: .relaxed)))
        let nextReference = reference + (db - reference) * (1 - exp(-duration / 0.24))
        referenceDB.store(Float(nextReference).bitPattern, ordering: .relaxed)
        // A held chord settles back to the base light. Only a fresh rise above
        // the running reference drives the faster highlight around the bezel.
        let rise = min(1, max(0, (db - reference - 2.5) / 11))
        let noiseGate = min(1, max(0, (db + 72) / 16))
        let previousAccent = resumed ? 0 : Double(Float(bitPattern: accent.load(ordering: .relaxed)))
        let nextAccent = max(rise * noiseGate, previousAccent * exp(-duration / 0.10))
        accent.store(Float(nextAccent).bitPattern, ordering: .relaxed)
        lastSample.store(now, ordering: .releasing)
    }
}

/// The detector and its working epoch are confined to HAL's serial IO queue. UI and device
/// lifecycle code only touch atomics. Invalidating the epoch immediately hides old-song beats.
private final class StudioBeatCapture: @unchecked Sendable {
    private let enabled = Atomic<Bool>(false)
    private let epoch = Atomic<UInt64>(1)
    private let publishedEpoch = Atomic<UInt64>(0)
    private let tempoBits = Atomic<UInt32>(0)
    private let strength = Atomic<UInt32>(0)
    private let beatTime = Atomic<UInt64>(0)
    private let sampleTime = Atomic<UInt64>(0)
    private let frequency = AudioGetHostClockFrequency()
    private var detector = StudioBeatDetector()
    private var workingEpoch: UInt64 = 0

    var beat: Double {
        guard enabled.load(ordering: .relaxed),
              publishedEpoch.load(ordering: .acquiring) == epoch.load(ordering: .acquiring) else { return 0 }
        let stamp = beatTime.load(ordering: .acquiring)
        guard stamp > 0 else { return 0 }
        let now = AudioGetCurrentHostTime()
        let age = Double(now >= stamp ? now - stamp : 0) / frequency
        let amplitude = Double(Float(bitPattern: strength.load(ordering: .relaxed)))
        return amplitude * exp(-age / 0.115)
    }

    var tempo: Double? {
        guard enabled.load(ordering: .relaxed),
              publishedEpoch.load(ordering: .acquiring) == epoch.load(ordering: .acquiring) else { return nil }
        let stamp = sampleTime.load(ordering: .acquiring)
        let now = AudioGetCurrentHostTime()
        guard stamp > 0, now >= stamp, Double(now - stamp) / frequency < 0.45 else { return nil }
        let bpm = Float(bitPattern: tempoBits.load(ordering: .relaxed))
        return bpm > 0 ? Double(bpm) : nil
    }

    func invalidate() {
        epoch.wrappingAdd(1, ordering: .releasing)
    }

    func setEnabled(_ value: Bool) {
        if enabled.exchange(value, ordering: .acquiringAndReleasing) != value { invalidate() }
    }

    func consume(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        guard enabled.load(ordering: .acquiring) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0, let bytes = first.mData else { return }
        let left = UnsafePointer(bytes.assumingMemoryBound(to: Float.self))
        let leftStride = Int(first.mNumberChannels)
        var frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.stride * leftStride)
        var right = left, rightStride = leftStride
        if leftStride > 1 {
            right = left.advanced(by: 1)
        } else if buffers.count > 1, let second = buffers[1].mData, buffers[1].mNumberChannels > 0 {
            right = UnsafePointer(second.assumingMemoryBound(to: Float.self))
            rightStride = Int(buffers[1].mNumberChannels)
            frames = min(frames, Int(buffers[1].mDataByteSize) / (MemoryLayout<Float>.stride * rightStride))
        }
        let currentEpoch = epoch.load(ordering: .acquiring)
        let now = AudioGetCurrentHostTime()
        let previous = sampleTime.load(ordering: .relaxed)
        if workingEpoch != currentEpoch || (previous > 0 && now > previous && Double(now - previous) / frequency > 0.55) {
            detector.reset()
            beatTime.store(0, ordering: .releasing)
            workingEpoch = currentEpoch
        }
        if let hit = detector.consume(left: left, leftStride: leftStride, right: right, rightStride: rightStride,
                                      frames: frames, rate: sampleRate) {
            strength.store(Float(hit.strength).bitPattern, ordering: .relaxed)
            let elapsed = UInt64(hit.age * frequency)
            beatTime.store(now > elapsed ? now - elapsed : now, ordering: .releasing)
        }
        tempoBits.store(Float(detector.tempo ?? 0).bitPattern, ordering: .relaxed)
        sampleTime.store(now, ordering: .releasing)
        publishedEpoch.store(currentEpoch, ordering: .releasing)
    }
}
