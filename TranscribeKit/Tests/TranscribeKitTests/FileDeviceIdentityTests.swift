import Foundation
import Testing
@testable import TranscribeKit

@Suite struct FileDeviceIdentityTests {
    @Test func createsOnceThenReadsTheSameID() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fdi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FileDeviceIdentity(root: root).installID()
        #expect(UUID(uuidString: first) != nil)
        #expect(FileDeviceIdentity(root: root).installID() == first)
        let stored = try String(contentsOf: root.appending(path: "InstallID"), encoding: .utf8)
        #expect(stored == first)
    }

    @Test func unwritableRootIsUnknown() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "fdi-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // The root is a regular file, so nothing can be created under it.
        #expect(FileDeviceIdentity(root: file).installID() == "")
    }
}
