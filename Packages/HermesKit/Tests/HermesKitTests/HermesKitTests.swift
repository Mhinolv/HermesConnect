import Testing
@testable import HermesKit

@Test func versionIsSet() {
    #expect(!HermesKit.version.isEmpty)
}
