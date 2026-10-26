import Darwin
import Foundation

public enum PermissionState: Sendable, Equatable {
    case granted, denied
    /// The probe could not tell (the file it reads is not there, or failed for another reason).
    case unknown
}

/// What macOS lets this process read, asked by trying. The answer is for the process that asks: an agent's
/// `macmax mcp` runs in its terminal's context, so MacMax's own grant never widens what an agent can read.
public enum PermissionProbe {
    /// The TCC database is readable only with Full Disk Access, and every Mac has it.
    static let fullDiskAccessFile = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// `open` returns 0 when the file could be opened, else the errno.
    public static func fullDiskAccess(open: (String) -> Int32 = { path in
        let descriptor = Darwin.open(path, O_RDONLY)
        if descriptor >= 0 { close(descriptor); return 0 }
        return errno
    }) -> PermissionState {
        switch open(fullDiskAccessFile) {
        case 0: .granted
        case EPERM, EACCES: .denied
        default: .unknown
        }
    }
}
