import Foundation
import Testing
@testable import HermesKit

/// Issue #173: the store contract with the in-memory store. No test reads the real Keychain.
@Suite struct ServeTokenStoreTests {
    private let home = UUID()
    private let lab = UUID()

    @Test func aSavedTokenLoadsAgainForItsServerOnly() throws {
        let store = InMemoryServeTokenStore()
        let token = SessionToken.mint()
        #expect(try store.loadToken(for: home) == nil)
        try store.saveToken(token, for: home)
        #expect(try store.loadToken(for: home) == token)
        #expect(try store.loadToken(for: lab) == nil)
    }

    @Test func aSaveReplacesTheOldTokenOfThatServer() throws {
        let store = InMemoryServeTokenStore()
        let old = SessionToken.mint()
        let new = SessionToken.mint()
        try store.saveToken(old, for: home)
        try store.saveToken(new, for: home)
        #expect(try store.loadToken(for: home) == new)
        #expect(store.servers == [home])
    }

    @Test func deleteRemovesOneServerAndDeleteAllRemovesEvery() throws {
        let store = InMemoryServeTokenStore()
        try store.saveToken(SessionToken.mint(), for: home)
        try store.saveToken(SessionToken.mint(), for: lab)
        try store.deleteToken(for: home)
        #expect(try store.loadToken(for: home) == nil)
        #expect(store.servers == [lab])
        try store.deleteToken(for: home)  // A second delete is not an error.
        try store.deleteAllTokens()
        #expect(store.servers.isEmpty)
    }

    @Test func theStoredBytesAreThe64HexCharactersAndRoundTrip() throws {
        let token = SessionToken.mint()
        #expect(token.storedBytes == token.stdinBytes)
        #expect(SessionToken(storedBytes: token.storedBytes) == token)
    }

    @Test(arguments: ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                      String(repeating: "g", count: 64), String(repeating: "a", count: 64) + "\n"])
    func damagedBytesGiveNoToken(text: String) {
        #expect(SessionToken(storedBytes: Data(text.utf8)) == nil)
    }

    @Test func theTokenIsRedactedInText() {
        let token = SessionToken.mint()
        #expect(!String(describing: token).contains(token.value))
        #expect(!String(reflecting: token).contains(token.value))
    }
}
