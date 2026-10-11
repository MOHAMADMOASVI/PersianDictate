import AVFoundation

/// Streams the default microphone as 16 kHz, mono, 16-bit PCM chunks.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "هیچ میکروفونی پیدا نشد."
            case .converterUnavailable: return "تبدیل فرمت صدا ممکن نیست."
            }
        }
    }

    static let sampleRate: Double = 16_000

    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// `onSamples` is called on the audio thread.
    func start(onSamples: @escaping ([Int16]) -> Void) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        let outputFormat = Self.format
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        converter.downmix = true

        let ratio = Self.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            guard Self.convert(buffer, with: converter, into: converted) else { return }
            onSamples(Self.samples(of: converted))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Helpers

    /// Feeds one input buffer through the converter; the resampler keeps its state between calls.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, into converted: AVAudioPCMBuffer) -> Bool {
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && converted.frameLength > 0
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// Wraps raw samples in a WAV container.
    static func wavData(_ samples: [Int16]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        let rate = UInt32(sampleRate)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(rebasing: $0[...])) }
        return data
    }
}
