import Foundation

/// A long-lived `nettop -P -L 0` child. A one-shot run loses a process's totals once its sockets close
/// (a short download vanishes); a running child keeps them. nettop prints no block terminator, so a
/// block counts as complete once its rows stop arriving for `quietSeconds`. nettop flushes a whole block
/// at once only when its stdout is a terminal (through a pipe it buffers 4 KB and a block's tail arrives
/// one sample late), so the child's stdout is a pty.
final class NettopStream: @unchecked Sendable {
    private static let header = ",bytes_in,bytes_out,"
    private static let quietSeconds = 0.2
    /// nettop does not exit when its reader goes away, so a shell stands guard: it ends nettop when the app
    /// exits, when nettop exits, or when it is terminated. Arguments are positional, never interpolated.
    private static let guardScript = """
    "$1" -P -L 0 -s "$2" -x -J bytes_in,bytes_out &
    child=$!
    finish() {
      kill $child 2>/dev/null
      for _ in 1 2 3 4 5; do kill -0 $child 2>/dev/null || exit 0; sleep 0.2; done
      kill -9 $child 2>/dev/null
      exit 0
    }
    trap finish TERM
    while kill -0 "$3" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
    finish
    """

    private let lock = NSLock()
    private var process: Process?
    private var reader: DispatchSourceRead?
    private var readerClosed: DispatchGroup?
    private var partialLine = ""
    private var block = ""
    private var sequence = 0
    private var generation = 0
    private var lastDataUptime: UInt64 = 0

    /// True while the child runs.
    var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    func start(executable: String, sampleSeconds: Int) throws {
        stop()
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            if master >= 0 { close(master) }
            throw CocoaError(.fileReadUnknown)
        }
        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw CocoaError(.fileReadUnknown)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", Self.guardScript, "sh", executable, String(sampleSeconds), String(getpid())]
        child.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let token = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "ro.danieltamas.macmax.nettop"))
        source.setEventHandler { [weak self, weak source] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(master, &buffer, buffer.count)
            if count > 0 { self?.receive(Data(buffer[..<count]), generation: token) } else { source?.cancel() }
        }
        let closed = DispatchGroup()
        closed.enter()
        source.setCancelHandler {
            close(master)
            closed.leave()
        }
        lock.withLock {
            partialLine = ""
            block = ""
            sequence = 0
            process = child
            reader = source
            readerClosed = closed
        }
        source.resume()
        do { try child.run() } catch {
            stop()
            close(slave)
            throw error
        }
        close(slave)
    }

    func stop() {
        let (child, source, closed) = lock.withLock { () -> (Process?, DispatchSourceRead?, DispatchGroup?) in
            defer { process = nil; reader = nil; readerClosed = nil }
            return (process, reader, readerClosed)
        }
        source?.cancel()
        // Wait for the master to close: a new start could otherwise be handed the same descriptor number
        // and have it closed by the old source's cancel handler.
        _ = closed?.wait(timeout: .now() + 1)
        guard let child, child.isRunning else { return }
        child.terminate()
        // The guard acts on TERM after its current sleep (up to 1 s) and then ends nettop (TERM, then KILL after 1 s); wait for it so a
        // restart never runs two children, and force it if it does not answer.
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while child.isRunning, DispatchTime.now().uptimeNanoseconds < deadline { usleep(20_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    /// The number of the block being received; it grows by one per nettop sample.
    var currentSequence: Int { lock.withLock { sequence } }

    /// The text of the newest block after `sequence`, once it has finished arriving; nil while it has not.
    func completedBlock(after previous: Int) -> String? {
        lock.withLock {
            guard sequence > previous, partialLine.isEmpty, block.hasSuffix("\n") else { return nil }
            let quiet = Double(DispatchTime.now().uptimeNanoseconds - lastDataUptime) / 1_000_000_000
            return quiet >= Self.quietSeconds ? block : nil
        }
    }

    /// Bytes from a child that was stopped are dropped, so a restart never starts with the old child's tail.
    private func receive(_ data: Data, generation token: Int) {
        // The pty turns "\n" into "\r\n", which Swift reads as one Character that never equals "\n".
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        lock.withLock {
            guard token == generation else { return }
            lastDataUptime = DispatchTime.now().uptimeNanoseconds
            partialLine += text
            while let newline = partialLine.firstIndex(of: "\n") {
                let line = partialLine[..<newline]
                partialLine = String(partialLine[partialLine.index(after: newline)...])
                if line == Self.header {
                    sequence += 1
                    block = ""
                }
                block += line + "\n"
            }
        }
    }
}
