import Foundation
import Testing
@testable import HermesKit

private let base = Date(timeIntervalSince1970: 1_763_290_000)

private func reply(_ text: String, reply state: ChatMessage.Reply = .complete) -> ChatRow {
    ChatTimeline.rows(for: [ChatMessage(id: "r1", role: .assistant, text: text, date: base, reply: state)])[0]
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ReceivedFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

// MARK: - MEDIA: tags

@Suite struct MediaTagTests {
    @Test func tagsLeaveTheTextInTagOrder() {
        let split = MediaTags.split("Here is the report:\n\nMEDIA:/home/hermes/.hermes/outputs/report.pdf\nMEDIA:/tmp/chart.png")
        #expect(split.text == "Here is the report:")
        #expect(split.files.map(\.path) == ["/home/hermes/.hermes/outputs/report.pdf", "/tmp/chart.png"])
        #expect(split.files.map(\.name) == ["report.pdf", "chart.png"])
        #expect(split.files.map(\.kind) == [.file, .image])
    }

    @Test func quotedAndSpacedPathsKeepEachCharacter() {
        #expect(MediaTags.split(#"MEDIA:"/tmp/my report.pdf""#).files.map(\.path) == ["/tmp/my report.pdf"])
        #expect(MediaTags.split("MEDIA:`/x/song.mp3`").files.map(\.path) == ["/x/song.mp3"])
        #expect(MediaTags.split("MEDIA:'/tmp/stop!.md'").files.map(\.path) == ["/tmp/stop!.md"])
        // The anchored form takes spaces inside a name up to a known type.
        let spaced = MediaTags.split("See MEDIA:/tmp/Q3 sales chart.png now")
        #expect(spaced.files.map(\.path) == ["/tmp/Q3 sales chart.png"])
        #expect(spaced.text == "See  now")
    }

    @Test func bareTagsDropSentencePunctuation() {
        let split = MediaTags.split("Open MEDIA:/tmp/a.pdf. Then reply.")
        #expect(split.files.map(\.path) == ["/tmp/a.pdf"])
        #expect(split.text == "Open . Then reply.")
        #expect(MediaTags.split("MEDIA:relative/notes.txt,").files.map(\.path) == ["relative/notes.txt"])
    }

    @Test func proseAfterMediaIsNotAFile() {
        for text in ["The MEDIA: tag is how files arrive.", "MEDIA:...", "MEDIA:word", "no tag here"] {
            let split = MediaTags.split(text)
            #expect(split.files.isEmpty, "\(text)")
            #expect(split.text == text)
        }
    }

    @Test func onlyTagsGiveNoText() {
        let split = MediaTags.split("MEDIA:/tmp/a.png\nMEDIA:/tmp/a.png\n")
        #expect(split.text.isEmpty)
        // A path shows once.
        #expect(split.files.map(\.path) == ["/tmp/a.png"])
    }

    @Test func kindsFollowTheExtension() {
        #expect(ReceivedFile(path: "/a/b.JPG").kind == .image)
        #expect(ReceivedFile(path: "/a/b.webp").kind == .image)
        #expect(ReceivedFile(path: "/a/b.svg").kind == .file)
        for ext in ["mp3", "m4a", "ogg", "wav"] { #expect(ReceivedFile(path: "/a/b.\(ext)").kind == .audio) }
        #expect(ReceivedFile.audioExtensions == ["mp3", "m4a", "ogg", "wav"])
        #expect(ReceivedFile(path: "C:\\out\\deck.pptx").name == "deck.pptx")
        #expect(ReceivedFile(path: "/").name == "File")
    }
}

// MARK: - Bubble parts

@Suite struct ReceivedFilePartTests {
    @Test func fileBubblesFollowTheTextBubble() {
        let parts = ChatBubbleParts.parts(for: reply("Done.\nMEDIA:/tmp/a.pdf\nMEDIA:/tmp/b.png"))
        #expect(parts.map(\.id) == ["r1", "r1#file0", "r1#file1"])
        #expect(parts[0].content == .text)
        #expect(parts[0].row.message.text == "Done.")
        #expect(parts.compactMap(\.receivedFile).map(\.name) == ["a.pdf", "b.png"])
        // The time header goes on the first bubble, the tail on the last one.
        #expect(parts[0].row.timeHeader != nil && parts[1].row.timeHeader == nil)
        #expect(parts.map(\.row.hasTail) == [false, false, true])
    }

    @Test func tagsOnlyShowOnlyFileBubbles() {
        let parts = ChatBubbleParts.parts(for: reply("MEDIA:/tmp/a.pdf"))
        #expect(parts.map(\.id) == ["r1"])
        #expect(parts[0].receivedFile?.path == "/tmp/a.pdf")
    }

    @Test func streamingReplyHidesTagsAndWaitsForTheEnd() {
        let parts = ChatBubbleParts.parts(for: reply("Making it now\nMEDIA:/tmp/rep", reply: .streaming))
        #expect(parts.map(\.content) == [.text])
        #expect(parts[0].row.message.text == "Making it now")
    }

    @Test func outgoingTextIsNeverParsed() {
        let row = ChatTimeline.rows(for: [ChatMessage(id: "u1", role: .user, text: "MEDIA:/tmp/a.png", date: base,
                                                      delivery: .delivered)])[0]
        #expect(ChatBubbleParts.parts(for: row).map(\.content) == [.text])
    }

    @Test func voiceOverLabels() {
        let row = reply("MEDIA:/tmp/report.pdf")
        #expect(ChatBubbleParts.receivedFileLabel(ReceivedFile(path: "/tmp/report.pdf"), byteCount: 2_000_000, row: row)
            == "Hermes sent a file, report.pdf, 2 MB")
        #expect(ChatBubbleParts.receivedFileLabel(ReceivedFile(path: "/tmp/a.png"), byteCount: 9, row: row)
            == "Hermes sent a photo")
        #expect(ChatBubbleParts.accessibilityLabel(for: ChatBubbleParts.parts(for: row)[0]) == "Hermes sent a file, report.pdf")
    }
}

// MARK: - Download request

private final class FakeFileLoader: HTTPFileDownloading, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var maxBytes: [Int?] = []
    var status = 200
    var size = 10
    var error: (any Error)?

    func download(_ request: URLRequest, maxBytes: Int?,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        let (status, size, error) = lock.withLock { () -> (Int, Int, (any Error)?) in
            requests.append(request)
            self.maxBytes.append(maxBytes)
            return (self.status, self.size, self.error)
        }
        if let error { throw error }
        if let maxBytes, size > maxBytes { throw ReceivedFileError.tooLarge(byteCount: size) }
        progress(1)
        let file = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)")
        try Data(repeating: 7, count: size).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct ReceivedFileDownloadTests {
    private let endpoint = try! GatewayEndpoint(port: 52001, token: "secrettoken")

    @Test func requestUsesTheDownloadRouteAndTheHeader() throws {
        let request = HermesRESTClient(endpoint: endpoint)
            .downloadRequest(path: "/home/hermes/out/a b+c&d.pdf", storedSessionId: "20261116_101500_ab12cd")
        let url = try #require(request.url)
        #expect(url.host == "127.0.0.1")
        #expect(url.path == "/api/fs/download")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "path" }?.value == "/home/hermes/out/a b+c&d.pdf")
        #expect(items.first { $0.name == "session_id" }?.value == "20261116_101500_ab12cd")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secrettoken")
        // The token never goes in the URL (docs/hermes-protocol.md 5.2).
        #expect(!url.absoluteString.contains("secrettoken"))
        #expect(url.query?.contains("%2B") == true)
    }

    @Test func statusCodesMapToStates() async throws {
        let loader = FakeFileLoader()
        let client = HermesRESTClient(endpoint: endpoint)
        for (status, expected) in [(403, ReceivedFileError.notAvailable), (404, .notAvailable)] {
            loader.status = status
            await #expect(throws: expected) {
                try await client.downloadFile(path: "/a.pdf", storedSessionId: "k", maxBytes: nil, using: loader)
            }
        }
        loader.status = 302
        await #expect(throws: HermesAPIError.http(status: 302)) {
            try await client.downloadFile(path: "/a.pdf", storedSessionId: "k", maxBytes: nil, using: loader)
        }
        loader.status = 401
        await #expect(throws: HermesAPIError.unauthorized) {
            try await client.downloadFile(path: "/a.pdf", storedSessionId: "k", maxBytes: nil, using: loader)
        }
        loader.status = 200
        let file = try await client.downloadFile(path: "/a.pdf", storedSessionId: "k", maxBytes: nil, using: loader)
        #expect(try Data(contentsOf: file).count == 10)
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Loader states

@MainActor
@Suite struct ReceivedFileLoaderTests {
    private func loader(_ fake: FakeFileLoader, folder: URL) -> ReceivedFileLoader {
        let client = HermesRESTClient(endpoint: try! GatewayEndpoint(port: 52001, token: "t"))
        return ReceivedFileLoader(download: { path, session, maxBytes, progress in
            try await client.downloadFile(path: path, storedSessionId: session, maxBytes: maxBytes, using: fake,
                                          progress: progress)
        }, folder: folder, storedSessionId: { "k1" }, prepareAudio: { url in VoiceReplyAudio(fileURL: url, duration: 3) })
    }

    @Test func downloadSavesTheFileAndARelaunchFindsIt() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeFileLoader()
        let files = loader(fake, folder: folder)
        var changes = 0
        files.onChange = { _ in changes += 1 }
        let file = ReceivedFile(path: "/home/hermes/out/../report.pdf")
        #expect(files.state(for: file) == .idle)
        await files.load(file)?.value
        let url = try #require(files.state(for: file).fileURL)
        #expect(url.lastPathComponent == "report.pdf")
        #expect(url.path.hasPrefix(folder.path))
        #expect(files.byteCount(for: file) == 10)
        #expect(changes >= 2)
        // The first call has the 50 MB limit.
        #expect(fake.maxBytes == [ReceivedFileLoader.confirmBytes])
        // A ready file does not download again. A new loader (a relaunch) finds it on disk.
        #expect(files.load(file) == nil)
        #expect(loader(fake, folder: folder).state(for: file) == .ready(url))
        #expect(fake.requests.count == 1)
    }

    @Test func largeFilesWaitForTheConfirm() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeFileLoader()
        fake.size = ReceivedFileLoader.confirmBytes + 1
        let files = loader(fake, folder: folder)
        let file = ReceivedFile(path: "/tmp/movie.mov")
        await files.load(file)?.value
        #expect(files.state(for: file) == .needsConfirmation(byteCount: ReceivedFileLoader.confirmBytes + 1))
        // An auto load (bubble shows again) does not start it. The confirm does.
        #expect(files.load(file) == nil)
        fake.size = 20
        await files.load(file, confirmed: true)?.value
        #expect(files.state(for: file).fileURL != nil)
        #expect(fake.maxBytes == [ReceivedFileLoader.confirmBytes, nil])
    }

    @Test func errorsGiveTheDesignStates() async {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeFileLoader()
        let files = loader(fake, folder: folder)
        fake.status = 404
        await files.load(ReceivedFile(path: "/gone.pdf"))?.value
        #expect(files.state(for: ReceivedFile(path: "/gone.pdf")) == .notAvailable)
        fake.status = 200
        fake.error = URLError(.cannotConnectToHost)
        await files.load(ReceivedFile(path: "/x.pdf"))?.value
        #expect(files.state(for: ReceivedFile(path: "/x.pdf")) == .offline)
        fake.error = URLError(.badServerResponse)
        await files.load(ReceivedFile(path: "/y.pdf"))?.value
        #expect(files.state(for: ReceivedFile(path: "/y.pdf")) == .failed)
        // A tap tries again.
        fake.error = nil
        await files.load(ReceivedFile(path: "/y.pdf"))?.value
        #expect(files.state(for: ReceivedFile(path: "/y.pdf")).fileURL != nil)
    }

    @Test func transportWithNoRESTIsOffline() {
        let files = ReceivedFileLoader(download: nil, folder: tempDirectory(), storedSessionId: { nil })
        let file = ReceivedFile(path: "/a.pdf")
        #expect(files.load(file) == nil)
        #expect(files.state(for: file) == .offline)
    }

    @Test func audioGetsTheBubbleAudioOnce() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = loader(FakeFileLoader(), folder: folder)
        let file = ReceivedFile(path: "/tmp/voice.ogg")
        #expect(files.audio(for: file) == .preparing)
        await files.load(file)?.value
        var ready: VoiceReplyAudio?
        files.onChange = { _ in ready = files.audio(for: file).audio }
        #expect(files.audio(for: file) == .preparing)
        for _ in 0..<100 where ready == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ready?.duration == 3)
    }

    @Test func namesStayInTheFolder() {
        #expect(ReceivedFileLoader.safeName("..") == "File")
        #expect(ReceivedFileLoader.safeName("a:b") == "a_b")
        let files = ReceivedFileLoader(download: nil, folder: URL(fileURLWithPath: "/tmp/rf"), storedSessionId: { "k" })
        let url = files.localURL(for: ReceivedFile(path: "/etc/../../passwd"))
        #expect(url.standardizedFileURL.path.hasPrefix("/tmp/rf/"))
    }
}

// MARK: - Cache and history

@Suite struct AttachmentCacheTests {
    private func sent() -> ChatMessage {
        let photo = ChatAttachment(id: "p1", kind: .photo, name: "IMG.jpg", byteCount: 1200,
                                   fileURL: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "tmp/p1/IMG.jpg"),
                                   mimeType: "image/jpeg", pixelWidth: 400, pixelHeight: 300, upload: .attached)
        let file = ChatAttachment(id: "f1", kind: .pdf, name: "Lease.pdf", byteCount: 2_400_000,
                                  fileURL: URL(fileURLWithPath: "/tmp/f1/Lease.pdf"), mimeType: "application/pdf",
                                  pageCount: 3, upload: .attached, refText: "@file:/home/hermes/attachments/Lease.pdf")
        return ChatMessage(id: "u1", role: .user, text: "Look", date: base, delivery: .delivered, userRowId: 4,
                           attachments: [photo, file])
    }

    @Test func attachmentsSurviveARelaunch() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        FileSessionCacheStore(directory: directory).saveTranscript([sent()], sessionId: "k1")
        let loaded = FileSessionCacheStore(directory: directory).loadTranscript(sessionId: "k1")
        #expect(loaded.count == 1)
        #expect(loaded[0].text == "Look")
        #expect(loaded[0].attachments == sent().attachments)
        // Issue #39 made it version 6.
        #expect(SessionCache.formatVersion >= 5)
    }

    @Test func version4FilesStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        let url = store.transcriptURL(sessionId: "k1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        {"version":4,"body":[
         {"id":"u1","role":"user","text":"Hi","date":1763290000,"userRowId":1,"interrupted":false,"notDelivered":false},
         {"id":"a1","role":"assistant","text":"Here MEDIA:/tmp/a.pdf","date":1763290001,"interrupted":false,
          "notDelivered":false,"speech":{"path":"~/x.mp3","duration":2,"waveform":[0.5]}},
         {"id":"u2","role":"user","text":"Bad","date":1763290002,"attachments":[{"kind":7}]}
        ]}
        """#.utf8).write(to: url)
        let loaded = store.loadTranscript(sessionId: "k1")
        #expect(loaded.map(\.id) == ["u1", "a1", "u2"])
        #expect(loaded.allSatisfy { $0.attachments.isEmpty })
        #expect(loaded[1].text == "Here MEDIA:/tmp/a.pdf")
        // The saved file is rewritten in the current version (5 for issue #12, 6 since issue #39).
        store.saveTranscript(loaded, sessionId: "k1")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"version\":\(SessionCache.formatVersion)"))
    }

    @Test func historyKeepsCachedFileBubbles() {
        // A relaunch: the cache shows the bubbles, then the server text with `@file:` refs merges in.
        let cached = [sent()]
        let transcript = [TranscriptMessage(role: "user", text: "@file:/home/hermes/attachments/Lease.pdf\n\nLook",
                                            rowId: 4)]
        let merged = ChatHistory.messages(from: transcript, reusing: cached)
        #expect(merged[0].text == "Look")
        #expect(merged[0].attachments.map(\.name) == ["IMG.jpg", "Lease.pdf"])
    }

    @Test func historyWithNoLocalItemsShowsFileCellsNotRefs() {
        let transcript = [TranscriptMessage(role: "user",
                                            text: "@file:/home/hermes/attachments/Lease.pdf\n@file:\"/w/My Notes.txt\"\n\nRead these",
                                            rowId: 9)]
        let merged = ChatHistory.messages(from: transcript)
        #expect(merged[0].text == "Read these")
        #expect(merged[0].attachments.map(\.name) == ["Lease.pdf", "My Notes.txt"])
        #expect(merged[0].attachments.map(\.kind) == [.pdf, .file])
        #expect(merged[0].attachments.allSatisfy { $0.upload == .attached && $0.byteCount == 0 })
        // Text with no refs, and a ref in the middle of text, stay as they are.
        #expect(AttachmentRefs.split("Hi @file:/a").paths.isEmpty)
        #expect(AttachmentRefs.split("@file:/a.txt").text.isEmpty)
    }
}
