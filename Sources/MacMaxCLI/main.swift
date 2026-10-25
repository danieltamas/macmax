import Foundation
import MacMaxCore

// install.sh recognizes a previous MacMax CLI by the literal "macmax-cli:" in this binary; keep it.
FileHandle.standardError.write(Data("macmax-cli: no commands yet\n".utf8))
exit(2)
