// Adapted for Graft, 2026-09-14. See Notices/FineTune.md for source and modifications.
// FineTune/Audio/Engine/TapResources.swift
import AudioToolbox
import os

/// Encapsulates Core Audio tap and aggregate device resources.
/// Provides safe cleanup with correct teardown order.
///
/// **Teardown order is critical:**
/// 1. Stop device proc (AudioDeviceStop)
/// 2. Destroy IO proc ID (AudioDeviceDestroyIOProcID) — blocks until callback finishes
/// 3. Destroy aggregate device (AudioHardwareDestroyAggregateDevice)
/// 4. Destroy process tap (AudioHardwareDestroyProcessTap)
///
/// Violating this order can leak HAL resources or crash on shutdown.
package struct TapResources {
    private static let logger = Logger(subsystem: "com.itsasheruwu.bliss-studio.audio", category: "TapResources")

    package var tapID: AudioObjectID = .unknown
    package var aggregateDeviceID: AudioObjectID = .unknown
    package var deviceProcID: AudioDeviceIOProcID?
    package var tapDescription: CATapDescription?

    /// Whether these resources are currently active
    package var isActive: Bool {
        tapID.isValid || aggregateDeviceID.isValid
    }

    /// Destroys all resources in the correct order to prevent leaks and crashes.
    /// Safe to call multiple times — invalid IDs are skipped.
    package mutating func destroy() {
        // Capture IDs before mutation (os.Logger autoclosure can't capture mutating self)
        let aggID = aggregateDeviceID
        let tID = tapID

        // Step 1 & 2: Stop and destroy IO proc
        if aggID.isValid {
            if let procID = deviceProcID {
                let stopErr = AudioDeviceStop(aggID, procID)
                if stopErr != noErr {
                    Self.logger.error("AudioDeviceStop failed for aggregate \(aggID): OSStatus \(stopErr)")
                }
                let destroyProcErr = AudioDeviceDestroyIOProcID(aggID, procID)
                if destroyProcErr != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed for aggregate \(aggID): OSStatus \(destroyProcErr)")
                }
            }
        }
        deviceProcID = nil

        // Step 3: Destroy aggregate device
        if aggID.isValid {

            let aggErr = AudioHardwareDestroyAggregateDevice(aggID)
            if aggErr != noErr {
                Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(aggID): OSStatus \(aggErr)")
            }
        }
        aggregateDeviceID = .unknown

        // Step 4: Destroy process tap
        if tID.isValid {
            let tapErr = AudioHardwareDestroyProcessTap(tID)
            if tapErr != noErr {
                Self.logger.error("AudioHardwareDestroyProcessTap failed for \(tID): OSStatus \(tapErr)")
            }
        }
        tapID = .unknown

        tapDescription = nil
    }
}
