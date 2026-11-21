import Foundation
import HermesKit
import Testing

/// Issue #18: on iOS the cache and attachment files get `completeUntilFirstUserAuthentication`, and the folders
/// have no backup. The Simulator has no Data Protection (it reads the attribute as nil), so these tests check
/// the request: the write options and each item that `ProtectedStorage.prepare` gives the class.
@Suite struct ProtectedStorageAppTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ProtectedStorageApp-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] { lock.withLock { _paths } }
        func record(_ url: URL) { lock.withLock { _paths.append(url.resolvingSymlinksInPath().path) } }
    }

    @Test func writesRequestTheProtectionClass() {
        #expect(ProtectedStorage.protection == .completeUntilFirstUserAuthentication)
        #expect(ProtectedStorage.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(ProtectedStorage.writeOptions.contains(.atomic))
    }

    @Test func cacheFolderHasNoBackupAfterTheFirstWrite() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        store.saveSessions([SessionListItem(id: "k1", title: "Trip")])
        FileSessionCacheStore.waitForWrites()
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
    }

    /// A file from a build before issue #18 gets the class when the folder is prepared, and still loads.
    @Test func olderFilesGetTheProtectionClassAndStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appending(path: "transcripts"), withIntermediateDirectories: true)
        let sessions = directory.appending(path: "sessions.json")
        let transcript = directory.appending(path: "transcripts/6b31.json")
        try Data(#"{"version":1,"body":[{"id":"k1","title":"Trip"}]}"#.utf8).write(to: sessions, options: .noFileProtection)
        try Data(#"{"version":1,"body":[]}"#.utf8).write(to: transcript, options: .noFileProtection)

        let recorder = Recorder()
        try ProtectedStorage.prepare(directory: directory) { recorder.record($0) }
        let expected = [directory, sessions, transcript].map { $0.resolvingSymlinksInPath().path }
        #expect(Set(recorder.paths).isSuperset(of: expected))
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
        #expect(FileSessionCacheStore(directory: directory).loadSessions() == [SessionListItem(id: "k1", title: "Trip")])
    }
}
