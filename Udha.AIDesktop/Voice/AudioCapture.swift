import Foundation
@preconcurrency import AVFoundation
import os

@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var tapInstalled: Bool = false
    nonisolated(unsafe) private var converter: AVAudioConverter?

    var onAudioChunk: ((Data) -> Void)?

    let preferredDeviceUID: String?

    init(sampleRate: Double = 16000, preferredDeviceUID: String? = nil) {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: sampleRate,
                                          channels: 1,
                                          interleaved: true)!
        self.preferredDeviceUID = preferredDeviceUID
    }

    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() async throws {
        guard !tapInstalled else { return }

        let granted = await Self.requestPermission()
        guard granted else {
            Log.voice.error("AudioCapture: mic permission denied")
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied. Open System Settings → Privacy & Security → Microphone and enable Udha.AIDesktop."])
        }

        if let uid = preferredDeviceUID, !uid.isEmpty,
           let deviceID = AudioDeviceLister.deviceID(forUID: uid) {
            var mutableID = deviceID
            let unit = engine.inputNode.audioUnit
            let status = AudioUnitSetProperty(
                unit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                Log.voice.info("AudioCapture: using device \(uid)")
            } else {
                Log.voice.error("AudioCapture: failed to set input device (status \(status))")
            }
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        if inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let data = self.encodeToPCM16(buffer: buffer)
            if !data.isEmpty {
                Task { @MainActor in
                    self.onAudioChunk?(data)
                }
            }
        }
        tapInstalled = true

        try await Task.detached { [engine] in
            engine.prepare()
            try engine.start()
        }.value
        Log.voice.info("AudioCapture started")
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    nonisolated private func encodeToPCM16(buffer: AVAudioPCMBuffer) -> Data {
        if buffer.format.commonFormat == .pcmFormatInt16 && buffer.format.sampleRate == targetFormat.sampleRate {
            let frames = Int(buffer.frameLength)
            guard frames > 0, let src = buffer.int16ChannelData?[0] else { return Data() }
            return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
        }
        guard let converter else { return Data() }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return Data() }
        var done = false
        var error: NSError?
        _ = converter.convert(to: outBuffer, error: &error) { _, status in
            if done {
                status.pointee = .noDataNow
                return nil
            }
            done = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return Data() }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let src = outBuffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
    }
}
