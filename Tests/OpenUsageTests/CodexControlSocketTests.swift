import Darwin
import XCTest
@testable import OpenUsage

@MainActor
final class CodexControlSocketTests: XCTestCase {
    func testAcceptsPrivateSocketAndOwnedLinkToPrivateSocket() throws {
        try withSocket { directory, socket in
            XCTAssertEqual(try CodexControlConnection.validateSocket(socket.path), socket.path)
            let link = directory.appendingPathComponent("control.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: socket)
            XCTAssertEqual(try CodexControlConnection.validateSocket(link.path),
                           "/private" + socket.path)
        }
    }

    func testRejectsLinkToSocketWithPublicPermissions() throws {
        try withSocket { directory, socket in
            let link = directory.appendingPathComponent("control.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: socket)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: socket.path)
            assertUnsafe(link.path)
        }
    }

    func testRejectsLinkWhenEitherParentAllowsOtherWriters() throws {
        try withSocket { directory, socket in
            let link = directory.appendingPathComponent("control.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: socket)
            let targetParent = socket.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: targetParent.path)
            assertUnsafe(link.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetParent.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
            assertUnsafe(link.path)
        }
    }

    func testRejectsRegularFileAndLinkToRegularFile() throws {
        try withSocket { directory, _ in
            let file = directory.appendingPathComponent("regular")
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let link = directory.appendingPathComponent("control.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            assertUnsafe(file.path)
            assertUnsafe(link.path)
        }
    }

    func testMissingAndLoopingLinksFailWithoutConnecting() throws {
        try withSocket { directory, _ in
            let link = directory.appendingPathComponent("control.sock")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
            XCTAssertThrowsError(try CodexControlConnection.validateSocket(link.path)) {
                XCTAssertEqual($0 as? SoftLimitControlError, .unavailable)
            }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "control.sock")
            XCTAssertThrowsError(try CodexControlConnection.validateSocket(link.path)) {
                XCTAssertEqual($0 as? SoftLimitControlError, .unavailable)
            }
        }
    }

    private func assertUnsafe(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CodexControlConnection.validateSocket(path), file: file, line: line) {
            XCTAssertEqual($0 as? SoftLimitControlError, .unsafeEndpoint, file: file, line: line)
        }
    }

    private func withSocket(_ verify: (URL, URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/tmp/ou-control-\(UUID().uuidString.prefix(8))")
        let target = directory.appendingPathComponent("daemon")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = target.appendingPathComponent("socket")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try verify(directory, path)
    }
}
