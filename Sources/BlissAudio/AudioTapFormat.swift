import AudioToolbox
import Foundation

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    var isValid: Bool { self != .unknown }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &format)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return format
    }
}
