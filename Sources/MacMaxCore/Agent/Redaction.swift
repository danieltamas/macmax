import Foundation

/// Secrets never leave the process unredacted: argv is redacted before it is stored, shown or
/// returned. Every rule lives here so one file answers "what do we redact".
public enum Redaction {
    public static let marker = "[redacted]"

    // MARK: Rules

    /// Flag names whose value is a secret: `--api-key`, `--token`, `--client-secret`, `--password`...
    private static let secretFlagName = try! NSRegularExpression(
        pattern: #"^--(?:key|credentials?|(?!(?:max|min|num)[-_]|count)(?:[a-z0-9]+[-_])*(?:api[-_]?key|access[-_]?key|private[-_]?key|token|password|passwd|secret|auth|authorization|credentials?))$"#,
        options: [.caseInsensitive])
    /// `NAME=value` where NAME ends in KEY, TOKEN, SECRET, PASSWORD or similar.
    private static let secretAssignment = try! NSRegularExpression(
        pattern: #"^((?:[A-Za-z_][A-Za-z0-9_]*_)?(?:API|ACCESS|PRIVATE|AUTH)?(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?))=(.*)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    /// `Bearer x`, `Basic x`, `Token x` anywhere in an argument.
    private static let authScheme = try! NSRegularExpression(
        pattern: #"\b(Bearer|Basic|Token)(\s+)(\S+)"#, options: [.caseInsensitive])
    /// A header or `name=value` pair whose name says credential: `X-Api-Key: value`, `Private-Token: value`, `Cookie: value`.
    private static let credentialHeader = try! NSRegularExpression(
        pattern: #"(?:(?<![A-Za-z0-9-])|(?<=^-[A-Za-z]))((?:[A-Za-z0-9]+-)*(?:authorization|authentication|auth|token|key|secret|password|cookie|credentials?)(?:-[A-Za-z0-9]+)*\s*[:=]\s*+)(?!(?:bearer|basic|token)\s)(.+)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    /// A credential header name split from its value by the shell: `Private-Token:` then `value`.
    private static let credentialHeaderName = try! NSRegularExpression(
        pattern: #"^(?:[A-Za-z0-9]+-)*(?:authorization|authentication|auth|token|key|secret|password|cookie|credentials?)(?:-[A-Za-z0-9]+)*:$"#,
        options: [.caseInsensitive])
    /// `scheme://user:pass@host`: the user information goes.
    private static let urlCredentials = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s@]+@"#)
    private static let entropyCharset = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+=")
    /// `header.payload.signature` with a base64url JSON header, the shape of a JWT.
    private static let jsonWebToken = try! NSRegularExpression(pattern: #"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$"#)
    /// A UUID is an identifier, not a secret, however random it looks.
    private static let uuid = try! NSRegularExpression(
        pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.caseInsensitive])
    /// A lone argument after which the next one is the credential: `Authorization: Bearer x` split by the shell.
    private static let secretWords: Set<String> = ["bearer", "basic", "token", "authorization", "authorization:", "x-api-key",
                                                    "x-api-key:", "cookie", "cookie:"]
    private static let minimumSecretLength = 32
    private static let minimumEntropyBitsPerCharacter = 3.5

    // MARK: Redaction

    public static func redact(_ argv: [String]) -> [String] {
        var result: [String] = []
        // The next argument is a secret: after a bare secret flag, or after a lone `Bearer` / `Basic`.
        var nextIsSecret = false
        // After `Authorization:` the scheme word is kept and the credential behind it goes; after a secret flag everything goes.
        var keepSchemeWord = false
        for argument in argv {
            let lowercased = argument.lowercased()
            if nextIsSecret {
                // `Authorization:` `Bearer` `x`: the scheme word stays, the credential after it goes.
                if keepSchemeWord ? secretWords.contains(lowercased) : matches(secretFlagName, argument) {
                    result.append(argument)
                } else {
                    result.append(marker)
                    nextIsSecret = false
                }
                continue
            }
            let isSecretFlag = matches(secretFlagName, argument)
            nextIsSecret = isSecretFlag || secretWords.contains(lowercased) || matches(credentialHeaderName, argument)
            keepSchemeWord = !isSecretFlag
            result.append(redact(argument))
        }
        return result
    }

    private static func redact(_ argument: String) -> String {
        // URL credentials first: `user:pass@host/x` must not pass as "a path".
        var text = replace(urlCredentials, in: argument, with: "$1\(marker)@")
        if let assignment = firstMatch(secretAssignment, in: text) {
            return "\(substring(assignment, 1, in: text))=\(marker)"
        }
        if let flag = flagAssignment(text) { return flag }
        text = replace(credentialHeader, in: text, with: "$1\(marker)")
        text = replace(authScheme, in: text, with: "$1$2\(marker)")
        if text.contains(where: \.isWhitespace) { return redactEmbeddedSecrets(in: text) }
        return looksLikeSecret(text) ? marker : text
    }

    /// `--api-key=value` -> `--api-key=[redacted]`; any other `--flag=value` has its value checked for entropy.
    private static func flagAssignment(_ text: String) -> String? {
        guard text.hasPrefix("--"), let equals = text.firstIndex(of: "=") else { return nil }
        let name = String(text[..<equals]), value = String(text[text.index(after: equals)...])
        if matches(secretFlagName, name) { return "\(name)=\(marker)" }
        return looksLikeSecret(value) ? "\(name)=\(marker)" : nil
    }

    /// A shell command line passed as one argument (`sh -c '...'`): its words are redacted like an argv
    /// (a word has no whitespace, so this ends). Runs of whitespace collapse to one space.
    private static func redactEmbeddedSecrets(in text: String) -> String {
        redact(text.split(whereSeparator: \.isWhitespace).map(String.init)).joined(separator: " ")
    }

    /// A long run of token characters with no `/` (paths pass) and enough variety to be random.
    private static func looksLikeSecret(_ text: String) -> Bool {
        if matches(jsonWebToken, text) { return true }
        guard text.count >= minimumSecretLength, !text.contains("/"), !matches(uuid, text),
              text.unicodeScalars.allSatisfy({ entropyCharset.contains($0) }) else { return false }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        let entropy = counts.values.reduce(0.0) { $0 - (Double($1) / length) * log2(Double($1) / length) }
        return entropy >= minimumEntropyBitsPerCharacter
    }

    // MARK: Text sanitizing

    private static let terminalSequences = try! NSRegularExpression(
        pattern: #"\x{1B}[PX^_].*?\x{1B}\\|\x{1B}\[[0-?]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|\x{1B}[@-Z\\-_]"#,
        options: [.dotMatchesLineSeparators])

    /// Removes control characters, terminal escapes and invisible Unicode (bidi marks, zero-width
    /// and soft hyphen) from untrusted display text.
    public static func sanitizeText(_ text: String) -> String {
        let withoutSequences = replace(terminalSequences, in: text, with: "")
        var scalars = String.UnicodeScalarView()
        for scalar in withoutSequences.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: Regex helpers

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        firstMatch(regex, in: text) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func substring(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> String {
        Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
    }
}
