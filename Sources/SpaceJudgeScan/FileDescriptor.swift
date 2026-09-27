import Darwin
import Foundation

/// Small RAII owner for a POSIX file descriptor.
///
/// Each descriptor is owned by exactly one worker at a time. It is marked
/// `@unchecked Sendable` only so a pre-opened root descriptor can be handed to
/// the worker that will consume it; ownership is transferred, never shared.
final class FileDescriptor: @unchecked Sendable {
    private var descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    var rawValue: Int32 { descriptor }

    var isValid: Bool { descriptor >= 0 }

    func close() {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

enum POSIXPath {
    /// Calls `open(2)` with an arbitrary byte path. Building the C string from
    /// raw bytes avoids assuming the path is valid UTF-8.
    static func open(_ path: [UInt8], flags: Int32) -> Int32 {
        var cString = path.map { CChar(bitPattern: $0) }
        cString.append(0)
        return cString.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.open(base, flags)
        }
    }

    /// Appends a single path component (`/name`) to a parent path.
    static func appending(_ parent: [UInt8], _ component: [UInt8]) -> [UInt8] {
        guard !parent.isEmpty else {
            return component
        }
        if parent.last == UInt8(ascii: "/") {
            return parent + component
        }
        return parent + [UInt8(ascii: "/")] + component
    }
}
