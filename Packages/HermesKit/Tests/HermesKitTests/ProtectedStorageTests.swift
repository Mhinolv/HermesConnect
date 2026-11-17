import Foundation
import Testing
@testable import HermesKit

/// Issue #18: the cache folder is excluded from backup, and files of older builds still load.
/// The protection class exists on iOS only. `HermesConnectTests/ProtectedStorageAppTests` checks it on the Simulator.
@Suite struct ProtectedStorageTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ProtectedStorage-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func writeOptionsAreAtomicAndUseTheProtectionClass() {
        #expect(ProtectedStorage.protection == .completeUntilFirstUserAuthentication)
        #expect(ProtectedStorage.writeOptions.contains(.atomic))
        #if os(iOS)
        #expect(ProtectedStorage.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #endif
    }

    @Test func prepareMakesTheFolderAndExcludesItFromBackup() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try ProtectedStorage.prepare(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
        try ProtectedStorage.prepare(directory: directory)  // Safe to call again.
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
    }

    @Test func cacheFolderIsExcludedFromBackupAfterTheFirstWrite() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        store.saveDraft("draft", sessionId: "k1")
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
    }

    /// A folder from a build before issue #18: no backup flag. The next write sets it, and the old files still load.
    @Test func filesSavedBeforeTheChangeStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = FileSessionCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: old.transcriptURL(sessionId: "k1").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"version":1,"body":[{"id":"m1","role":"user","text":"Hi","date":1763290000}]}"#.utf8)
            .write(to: old.transcriptURL(sessionId: "k1"))
        try Data(#"{"version":1,"body":[{"id":"k1","title":"Trip"}]}"#.utf8).write(to: old.sessionsURL)
        #expect(!ProtectedStorage.isExcludedFromBackup(directory))

        let store = FileSessionCacheStore(directory: directory)
        store.saveActiveSessionId("k1")
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
        #expect(store.loadTranscript(sessionId: "k1").map(\.text) == ["Hi"])
        #expect(store.loadSessions() == [SessionListItem(id: "k1", title: "Trip")])
        #expect(store.loadActiveSessionId() == "k1")
    }
}
