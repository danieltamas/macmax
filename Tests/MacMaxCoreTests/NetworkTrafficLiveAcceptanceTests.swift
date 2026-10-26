import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private final class LocalHTTPServer: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "ro.danieltamas.macmax.tests.http-server")
    let port: Int

    init() throws {
        let localDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard localDescriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var reuse: Int32 = 1
        guard setsockopt(localDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            Darwin.close(localDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(localDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(localDescriptor, 4) == 0 else {
            Darwin.close(localDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(localDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(localDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptor = localDescriptor
        port = Int(UInt16(bigEndian: bound.sin_port))
        queue.async { [self] in serve() }
    }

    func stop() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func serve() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            serve(client)
            Darwin.close(client)
        }
    }

    private func serve(_ client: Int32) {
        var request = [UInt8](repeating: 0, count: 1_024)
        guard recv(client, &request, request.count, 0) > 0 else { return }
        let byteCount = 5 * 1_024 * 1_024
        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(byteCount)\r\nConnection: keep-alive\r\n\r\n"
        guard sendAll(client, bytes: Array(header.utf8)) else { return }
        let chunk = [UInt8](repeating: 65, count: 64 * 1_024)
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            guard sendAll(client, bytes: Array(chunk.prefix(count))) else { return }
            remaining -= count
        }
        var byte: UInt8 = 0
        while Darwin.recv(client, &byte, 1, 0) > 0 {}
    }

    private func sendAll(_ client: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.send(client, baseAddress.advanced(by: sent), buffer.count - sent, 0)
                guard result > 0 else { return false }
                sent += result
            }
            return true
        }
    }
}

private func liveReadingFailed<Value>(_ reading: Reading<Value>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func rawHTTPDownload(port: Int) throws -> (descriptor: Int32, statusCode: Int, bodyByteCount: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    var closeOnReturn = true
    defer {
        if closeOnReturn { Darwin.close(descriptor) }
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connectResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let request = Array("GET /five-mebibytes HTTP/1.0\r\n\r\n".utf8)
    try request.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let result = Darwin.send(
                descriptor,
                baseAddress.advanced(by: sent),
                buffer.count - sent,
                0
            )
            guard result > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            sent += result
        }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if received == 0 { throw POSIXError(.ECONNRESET) }
        if received < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        response.append(contentsOf: buffer.prefix(received))

        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = response.range(of: separator) else { continue }
        let headerData = response[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8),
              let statusCode = header.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
              let contentLengthLine = header.components(separatedBy: "\r\n").first(where: {
                  $0.lowercased().hasPrefix("content-length:")
              }),
              let contentLength = Int(contentLengthLine.split(separator: ":", maxSplits: 1)[1]
                  .trimmingCharacters(in: .whitespaces))
        else {
            throw POSIXError(.EBADMSG)
        }
        let bodyByteCount = response.distance(from: headerRange.upperBound, to: response.endIndex)
        guard bodyByteCount >= contentLength else { continue }
        closeOnReturn = false
        return (descriptor, statusCode, bodyByteCount)
    }
}

@Suite(
    "NetworkTrafficLiveAcceptance",
    .enabled(if: ProcessInfo.processInfo.environment["MACMAX_LIVE"] == "1")
)
struct NetworkTrafficLiveAcceptanceTests {
    @Test("local five MiB download appears in this process interval")
    func localDownload() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let processCollector = ProcessCollector()
        let networkCollector = NetworkCollector()
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)

        let firstProcesses = try #require((await processCollector.collect()).value)
        _ = await networkCollector.collect(processes: firstProcesses)
        let download = try await Task.detached {
            try rawHTTPDownload(port: server.port)
        }.value
        defer { Darwin.close(download.descriptor) }
        #expect(download.bodyByteCount >= 5 * 1_024 * 1_024)
        #expect(download.statusCode == 200)

        let secondProcesses = try #require((await processCollector.collect()).value)
        let ownIdentity = try #require(secondProcesses.first { $0.identity.pid == ownPid }?.identity)
        let snapshot = await networkCollector.collect(processes: secondProcesses)
        let readings = try #require(snapshot.processes.value)
        let ownCounters = try #require(readings[ownIdentity]?.value)
        #expect(ownCounters.bytesIn >= 5 * 1_024 * 1_024)
        #expect(readings[ownIdentity].map { !liveReadingFailed($0) } == true)
        #expect(snapshot.skippedRows >= 0)

        let rates = try #require(snapshot.interfaces.value)
        #expect(rates.allSatisfy { $0.bytesInPerSecond >= 0 && $0.bytesOutPerSecond >= 0 })
    }

    @Test("closed download is never reported as a smaller count")
    func closedDownload() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let processCollector = ProcessCollector()
        let networkCollector = NetworkCollector()
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)

        let firstProcesses = try #require((await processCollector.collect()).value)
        _ = await networkCollector.collect(processes: firstProcesses)
        let download = try await Task.detached {
            try rawHTTPDownload(port: server.port)
        }.value
        var openDescriptor: Int32? = download.descriptor
        defer {
            if let descriptor = openDescriptor { Darwin.close(descriptor) }
        }

        let secondProcesses = try #require((await processCollector.collect()).value)
        let ownIdentity = try #require(secondProcesses.first { $0.identity.pid == ownPid }?.identity)
        _ = await networkCollector.collect(processes: secondProcesses)
        Darwin.close(download.descriptor)
        openDescriptor = nil

        let afterCloseProcesses = try #require((await processCollector.collect()).value)
        let snapshot = await networkCollector.collect(processes: afterCloseProcesses)
        guard case let .ok(readings, _, _) = snapshot.processes,
              let ownReading = readings[ownIdentity]
        else { return }
        if case let .ok(counters, _, _) = ownReading {
            #expect(counters.bytesIn >= UInt64(download.bodyByteCount))
        }
    }

    @Test("connections reports the test process listening socket")
    func listenerConnection() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)

        let connections = try #require((await NetworkCollector().connections(ofPid: ownPid)).value)
        #expect(connections.contains { $0.localPort == server.port && $0.state == "Listen" })
    }
}
