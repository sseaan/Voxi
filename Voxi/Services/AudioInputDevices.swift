import AVFoundation
import CoreAudio
import Foundation

/// CoreAudio 输入设备枚举与引擎设备切换。
///
/// 不依赖 `AVCaptureDevice`（macOS 14+ 才有 microphone 类型），
/// 因此 macOS 13 也能列出设备。
enum AudioInputDevices {
    struct Device: Identifiable, Equatable {
        /// CoreAudio device UID，跨启动稳定。
        let id: String
        let name: String
    }

    /// 所有可录音的输入设备（按系统顺序）。
    static func all() -> [Device] {
        allDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, device: deviceID)
            else { return nil }
            return Device(id: uid, name: name(of: deviceID) ?? uid)
        }
    }

    /// 系统默认输入设备的 UID。
    static func systemDefaultUID() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, device: deviceID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// 把 AVAudioEngine 的输入节点切换到指定设备；失败时保持系统默认。
    @discardableResult
    static func select(uid: String, on engine: AVAudioEngine) -> Bool {
        guard let deviceID = deviceID(forUID: uid), let unit = engine.inputNode.audioUnit else {
            return false
        }
        var value = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    // MARK: - CoreAudio 查询

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, device: deviceID)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
