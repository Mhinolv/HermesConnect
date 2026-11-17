import Foundation
import Testing
@testable import HermesKit

/// The 16-bit samples of a WAV file that `WAVFile` wrote (44-byte header).
private func wavSamples(_ wav: Data) -> [Int16] {
    let bytes = [UInt8](wav.dropFirst(44))
    return stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
}

/// Writes Ogg pages with at most `bodySize` bytes each, so packets go across pages.
private func repaged(_ packets: [[UInt8]], endGranule: Int64, bodySize: Int, serial: UInt32 = 7) -> Data {
    var segments: [(lace: Int, bytes: ArraySlice<UInt8>)] = []
    for packet in packets {
        var rest = packet[...]
        while rest.count >= 255 {
            segments.append((255, rest.prefix(255)))
            rest = rest.dropFirst(255)
        }
        segments.append((rest.count, rest))
    }
    var data = Data()
    var index = 0
    var sequence: UInt32 = 0
    var continues = false
    while index < segments.count {
        var page: [(lace: Int, bytes: ArraySlice<UInt8>)] = []
        var size = 0
        while index < segments.count, page.count < 255, size + segments[index].lace <= max(bodySize, 255) {
            page.append(segments[index])
            size += segments[index].lace
            index += 1
        }
        var header: [UInt8] = Array("OggS".utf8) + [0]
        header.append((continues ? 0x01 : 0) | (sequence == 0 ? 0x02 : 0) | (index == segments.count ? 0x04 : 0))
        let granule = index == segments.count ? endGranule : -1
        header += withUnsafeBytes(of: granule.littleEndian, Array.init)
        header += withUnsafeBytes(of: serial.littleEndian, Array.init)
        header += withUnsafeBytes(of: sequence.littleEndian, Array.init)
        header += [0, 0, 0, 0, UInt8(page.count)] + page.map { UInt8($0.lace) }
        var bytes = header + page.flatMap(\.bytes)
        let crc = OggCRC.checksum(bytes[...], crcAt: 22)
        bytes.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        data.append(contentsOf: bytes)
        continues = page.last?.lace == 255
        sequence += 1
    }
    return data
}

@Suite struct OggOpusTests {
    @Test func fixtureHeadAndPackets() throws {
        let stream = try OggOpusStream(data: try fixture("voice-reply.ogg"))
        #expect(stream.head.channels == 1)
        #expect(stream.head.inputSampleRate == 24_000)
        #expect(stream.head.preSkip > 0)
        #expect(stream.packets.allSatisfy { OpusPacket.samples($0) == 960 })
        // The end granule minus the pre-skip is the source length: 1.5 s at 48 kHz.
        #expect(stream.outputSamples == 72_000)
    }

    /// The decoded length is the source length, and the audio is the 440 Hz tone, not silence.
    @Test func decodesTheToneAtTheSourceLength() throws {
        let wav = try OggOpus.wav(from: try fixture("voice-reply.ogg"))
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        let samples = wavSamples(wav)
        #expect(abs(Double(samples.count) / 48_000 - 1.5) < 0.1)
        let middle = samples[12_000..<60_000].map { Double($0) / Double(Int16.max) }
        let rms = (middle.reduce(0) { $0 + $1 * $1 } / Double(middle.count)).squareRoot()
        #expect(rms > 0.05)
        let crossings = zip(middle, middle.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        // 1 s of a 440 Hz tone crosses zero 880 times.
        #expect(abs(crossings - 880) < 20)
    }

    /// Packets that go across pages (lacing 255 and the "continued" flag) decode to the same audio.
    @Test(arguments: [255, 300, 4_000])
    func packetsAcrossPagesDecodeTheSame(bodySize: Int) throws {
        let original = try fixture("voice-reply.ogg")
        let stream = try OggOpusStream(data: original)
        let head = try OggPage.pages(in: [UInt8](original))
        let headers = head.prefix(2).map { Array($0.body) }
        let copy = repaged(headers + stream.packets, endGranule: stream.endGranule, bodySize: bodySize)
        #expect(copy != original)
        let again = try OggOpusStream(data: copy)
        #expect(again.packets == stream.packets)
        #expect(try OggOpus.wav(from: copy) == OggOpus.wav(from: original))
    }

    @Test func otherStreamsInTheFileAreIgnored() throws {
        let original = try fixture("voice-reply.ogg")
        let stream = try OggOpusStream(data: original)
        var copy = original
        copy.append(repaged([[0xF8, 1, 2, 3]], endGranule: 960, bodySize: 255, serial: 99))
        #expect(try OggOpusStream(data: copy).packets == stream.packets)
    }

    @Test(arguments: [
        ([0x18], 2_880),               // SILK 60 ms, 1 frame
        ([0x10 | 1], 2 * 1_920),                // SILK 40 ms, 2 frames
        ([0x60 | 2, 0, 0], 2 * 480),            // hybrid 10 ms, 2 frames
        ([0x80 | 3, 0x03], 3 * 120),            // CELT 2.5 ms, 3 frames
        ([0xF8 | 3, 0x06], 6 * 960),            // CELT 20 ms, 6 frames = 120 ms
        ([0xF8 | 3, 0x07], 0),                  // 140 ms is more than a packet holds
        ([0xF8 | 3], 0),                        // no frame count byte
        ([], 0),
    ] as [([UInt8], Int)])
    func packetSamplesFromTheTOC(packet: [UInt8], samples: Int) {
        #expect(OpusPacket.samples(packet) == samples)
    }

    @Test func multichannelAndBadHeadsAreRefused() throws {
        var head = Array("OpusHead".utf8) + [1, 1, 0x38, 0x01, 0xC0, 0x5D, 0, 0, 0, 0, 0]
        #expect(try OpusHead(packet: head).preSkip == 312)
        head[18] = 1
        #expect(throws: VoiceReplyError.cannotDecode) { try OpusHead(packet: head) }
        head[18] = 0
        head[9] = 3
        #expect(throws: VoiceReplyError.cannotDecode) { try OpusHead(packet: head) }
        head[9] = 1
        head[8] = 0x10
        #expect(throws: VoiceReplyError.cannotDecode) { try OpusHead(packet: head) }
        #expect(throws: VoiceReplyError.cannotDecode) { try OpusHead(packet: Array(head.prefix(18))) }
    }

    @Test(arguments: ["truncated", "headers only", "bad byte", "not a page"])
    func brokenOggThrows(kind: String) throws {
        #expect(throws: VoiceReplyError.cannotDecode) { try OggOpus.wav(from: try brokenOgg(kind)) }
    }

    @Test func oggVorbisIsRefused() {
        let vorbis = repaged([[0x01] + Array("vorbis".utf8), [0x03] + Array("vorbis".utf8), [0, 1, 2]],
                             endGranule: 100, bodySize: 255)
        #expect(OggOpus.isOgg(vorbis))
        #expect(throws: VoiceReplyError.cannotDecode) { try OggOpus.wav(from: vorbis) }
    }
}
