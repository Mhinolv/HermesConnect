import AVFoundation
import Foundation

/// Issue #42: the server TTS gives Ogg Opus voice replies (`data:audio/ogg;base64,...`).
/// AVAudioPlayer opens the Ogg file and reads its length, but it cannot play it.
/// This file demuxes the Ogg pages (RFC 3533) to Opus packets (RFC 7845) and decodes them with
/// `AVAudioConverter`. The result is a 16-bit PCM WAV file that AVAudioPlayer plays on iOS.
public enum OggOpus {
    /// The Opus decoder always runs at 48 kHz (RFC 7845 section 4).
    public static let sampleRate = 48_000
    /// A reply longer than 10 minutes is refused, so a bad stream cannot ask for a very large buffer.
    static let maximumSamples = sampleRate * 60 * 10

    /// `true` if the data starts with an Ogg page ("OggS").
    public static func isOgg(_ data: Data) -> Bool {
        data.starts(with: [0x4F, 0x67, 0x67, 0x53])
    }

    /// Decodes an Ogg Opus file to the bytes of a 16-bit PCM WAV file at 48 kHz.
    /// Throws `VoiceReplyError.cannotDecode` for a broken or unsupported stream.
    public static func wav(from data: Data) throws -> Data {
        let stream = try OggOpusStream(data: data)
        return WAVFile.data(samples: try stream.decode(), channels: stream.head.channels, rate: sampleRate)
    }
}

/// The `OpusHead` packet (RFC 7845 section 5.1).
struct OpusHead: Equatable {
    var channels: Int
    var preSkip: Int
    var inputSampleRate: Int
    /// Q7.8 dB.
    var outputGain: Int16

    init(packet: [UInt8]) throws {
        guard packet.count >= 19, packet.starts(with: Array("OpusHead".utf8)), packet[8] >> 4 == 0 else {
            throw VoiceReplyError.cannotDecode
        }
        channels = Int(packet[9])
        preSkip = Int(packet.uint16(at: 10))
        inputSampleRate = Int(packet.uint32(at: 12))
        outputGain = Int16(bitPattern: packet.uint16(at: 16))
        // Mapping family 0 is mono or stereo. The server gives mono. Multichannel streams are refused.
        guard packet[18] == 0, (1...2).contains(channels) else { throw VoiceReplyError.cannotDecode }
    }
}

/// The first logical Opus stream of an Ogg file: its head, its audio packets and the last granule position.
struct OggOpusStream {
    var head: OpusHead
    var packets: [[UInt8]]
    /// The granule position of the last page: the end of the audio, pre-skip included, at 48 kHz.
    var endGranule: Int64

    init(data: Data) throws {
        let pages = try OggPage.pages(in: [UInt8](data))
        guard let first = pages.first, first.isFirst else { throw VoiceReplyError.cannotDecode }
        let stream = pages.filter { $0.serial == first.serial }
        var packets: [[UInt8]] = []
        var partial: [UInt8]?
        for page in stream {
            // A page that does not continue a packet drops a packet that was not complete.
            var packet: [UInt8]? = page.continuesPacket ? partial : []
            var offset = page.body.startIndex
            for lace in page.lacing {
                packet? += page.body[offset..<offset + lace]
                offset += lace
                if lace < 255 {
                    if let packet { packets.append(packet) }
                    packet = []
                }
            }
            partial = (page.lacing.last.map { $0 == 255 } ?? page.continuesPacket) ? packet : nil
        }
        guard packets.count >= 2 else { throw VoiceReplyError.cannotDecode }
        head = try OpusHead(packet: packets[0])
        guard packets[1].starts(with: Array("OpusTags".utf8)) else { throw VoiceReplyError.cannotDecode }
        self.packets = Array(packets.dropFirst(2)).filter { !$0.isEmpty }
        endGranule = stream.last { $0.granule >= 0 }?.granule ?? -1
        guard !self.packets.isEmpty else { throw VoiceReplyError.cannotDecode }
    }

    /// The samples per channel of all packets, before the pre-skip and the end trim.
    var packetSamples: Int { packets.reduce(0) { $0 + OpusPacket.samples($1) } }

    /// The samples per channel to keep: the end granule minus the pre-skip (RFC 7845 section 4.4).
    var outputSamples: Int {
        let all = packetSamples
        guard endGranule >= 0 else { return max(0, all - head.preSkip) }
        return max(0, min(all, Int(clamping: endGranule)) - head.preSkip)
    }

    /// Decodes the packets to interleaved Float32 samples at 48 kHz, with the pre-skip and the end trim done.
    func decode() throws -> [Float] {
        let channels = head.channels
        let total = packetSamples
        let keep = outputSamples
        guard keep > 0, total <= OggOpus.maximumSamples, packets.allSatisfy({ OpusPacket.samples($0) > 0 }) else {
            throw VoiceReplyError.cannotDecode
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(OggOpus.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(OpusPacket.samples(packets[0])), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(OggOpus.sampleRate),
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw VoiceReplyError.cannotDecode
        }
        converter.primeMethod = .none

        // The input block gives one packet for each call. The converter is used on this thread only.
        let packets = self.packets
        nonisolated(unsafe) var next = 0
        var samples: [Float] = []
        samples.reserveCapacity(total * channels)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(OggOpus.sampleRate))
            else { throw VoiceReplyError.cannotDecode }
            var failure: NSError?
            let status = converter.convert(to: buffer, error: &failure) { _, inputStatus in
                guard next < packets.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let packet = packets[next]
                next += 1
                let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1,
                                                         maximumPacketSize: packet.count)
                packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
                compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: UInt32(OpusPacket.samples(packet)),
                    mDataByteSize: UInt32(packet.count))
                compressed.packetCount = 1
                compressed.byteLength = UInt32(packet.count)
                inputStatus.pointee = .haveData
                return compressed
            }
            guard status != .error, failure == nil, let data = buffer.floatChannelData else {
                throw VoiceReplyError.cannotDecode
            }
            samples += UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength) * channels)
            if status == .endOfStream || buffer.frameLength == 0 { break }
        }
        let start = head.preSkip * channels
        let end = start + keep * channels
        guard samples.count >= end else { throw VoiceReplyError.cannotDecode }
        let gain = head.outputGain == 0 ? 1 : Float(pow(10, Double(head.outputGain) / (256 * 20)))
        return gain == 1 ? Array(samples[start..<end]) : samples[start..<end].map { $0 * gain }
    }
}

/// One Ogg page (RFC 3533 section 6).
struct OggPage {
    var headerType: UInt8
    var granule: Int64
    var serial: UInt32
    var lacing: [Int]
    var body: ArraySlice<UInt8>

    var continuesPacket: Bool { headerType & 0x01 != 0 }
    var isFirst: Bool { headerType & 0x02 != 0 }

    /// Every page of the file. A bad capture pattern, a short page or a bad CRC throws.
    static func pages(in bytes: [UInt8]) throws -> [OggPage] {
        var pages: [OggPage] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 27, bytes[offset..<offset + 4].elementsEqual([0x4F, 0x67, 0x67, 0x53]),
                  bytes[offset + 4] == 0 else { throw VoiceReplyError.cannotDecode }
            let segments = Int(bytes[offset + 26])
            let bodyStart = offset + 27 + segments
            guard bodyStart <= bytes.count else { throw VoiceReplyError.cannotDecode }
            let lacing = bytes[offset + 27..<bodyStart].map(Int.init)
            let end = bodyStart + lacing.reduce(0, +)
            guard end <= bytes.count else { throw VoiceReplyError.cannotDecode }
            guard OggCRC.checksum(bytes[offset..<end], crcAt: offset + 22) == bytes.uint32(at: offset + 22) else {
                throw VoiceReplyError.cannotDecode
            }
            pages.append(OggPage(headerType: bytes[offset + 5],
                                 granule: Int64(bitPattern: bytes.uint64(at: offset + 6)),
                                 serial: bytes.uint32(at: offset + 14), lacing: lacing, body: bytes[bodyStart..<end]))
            offset = end
        }
        return pages
    }
}

/// The Ogg CRC-32: polynomial 0x04C11DB7, start 0, no reflection, the CRC field read as zero.
enum OggCRC {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    static func checksum(_ page: ArraySlice<UInt8>, crcAt crcOffset: Int) -> UInt32 {
        var crc: UInt32 = 0
        for index in page.indices {
            let byte = (crcOffset..<crcOffset + 4).contains(index) ? 0 : page[index]
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}

/// The TOC byte of an Opus packet (RFC 6716 section 3.1).
enum OpusPacket {
    /// The samples per channel at 48 kHz in the packet. 0 for a packet with no valid TOC.
    static func samples(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]
        case 12...15: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return 0 }
            frames = Int(packet[1] & 0x3F)
        }
        let samples = frame * frames
        // A packet holds no more than 120 ms of audio.
        return samples <= 5760 ? samples : 0
    }
}

/// A 16-bit PCM WAV file.
enum WAVFile {
    static func data(samples: [Float], channels: Int, rate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1))
        append(UInt16(channels)); append(UInt32(rate)); append(UInt32(rate * channels * 2))
        append(UInt16(channels * 2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}

private extension Collection where Element == UInt8, Index == Int {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
