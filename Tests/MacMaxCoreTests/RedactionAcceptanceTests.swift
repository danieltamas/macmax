import Testing
@testable import MacMaxCore

@Suite("RedactionAcceptance")
struct RedactionAcceptanceTests {
    @Test("Bearer authorization values are redacted without changing argv shape")
    func bearerHeader() {
        let input = ["curl", "-H", "Authorization: Bearer exampletoken1234567890", "https://example.com/x"]
        let expected = ["curl", "-H", "Authorization: Bearer [redacted]", "https://example.com/x"]
        let output = Redaction.redact(input)
        #expect(output == expected)
        #expect(output.count == input.count)
        #expect(!output.joined(separator: " ").contains("exampletoken1234567890"))
    }

    @Test("inline and separate secret flags preserve flag names")
    func secretFlags() {
        #expect(Redaction.redact(["--api-key=examplesecretvalue", "run"])
            == ["--api-key=[redacted]", "run"])
        #expect(Redaction.redact(["--token", "examplesecretvalue", "run"])
            == ["--token", "[redacted]", "run"])
        #expect(Redaction.redact(["--password", "examplesecretvalue", "run"])
            == ["--password", "[redacted]", "run"])
    }

    @Test("environment-style secret values are redacted and keys survive")
    func environmentStyleSecrets() {
        let input = [
            "GITHUB_TOKEN=examplevalue123",
            "MY_SERVICE_KEY=examplevalue123",
            "APP_SECRET=examplevalue123",
            "tool"
        ]
        let expected = [
            "GITHUB_TOKEN=[redacted]",
            "MY_SERVICE_KEY=[redacted]",
            "APP_SECRET=[redacted]",
            "tool"
        ]
        #expect(Redaction.redact(input) == expected)
    }

    @Test("URL user information is replaced while host and path survive")
    func urlCredentials() {
        let input = ["https://alice:hunter2example@example.com/repo.git"]
        let expected = ["https://[redacted]@example.com/repo.git"]
        let output = Redaction.redact(input)
        #expect(output == expected)
        #expect(!output[0].contains("alice"))
        #expect(!output[0].contains("hunter2example"))
    }

    @Test("standalone high-entropy value is redacted")
    func highEntropyValue() {
        let randomValue = "q8Zx3KdP0mVr7TnB2wYc5LhJ9sFa1GeU4oXi6RbN"
        #expect(randomValue.count == 40)
        #expect(Redaction.redact([randomValue]) == [Redaction.marker])
    }

    @Test("ordinary flags, values, commands, and long paths are unchanged")
    func ordinaryArguments() {
        let cases = [
            ["--model", "opus"],
            ["/Users/example/Projects/app/src/main.swift"],
            ["--max-turns", "12"],
            ["ls", "-la"],
            ["/Users/example/Projects/a-very-long-project-name/Sources/Feature/Implementation/main.swift"]
        ]
        for input in cases {
            #expect(Redaction.redact(input) == input)
        }
    }

    @Test("redaction is idempotent and preserves empty arguments and argument count")
    func structuralInvariants() {
        let inputs = [
            [String](),
            [""],
            ["", "--token", "examplesecretvalue", ""],
            ["--api-key=examplesecretvalue", "run"]
        ]
        for input in inputs {
            let once = Redaction.redact(input)
            #expect(once.count == input.count)
            #expect(Redaction.redact(once) == once)
        }
        #expect(Redaction.redact([]) == [])
        #expect(Redaction.redact([""]) == [""])
    }

    @Test("sanitizeText removes terminal controls and invisible characters only")
    func sanitizeText() {
        let unsafe = "start\u{0000}\u{0009}\u{001B}[31mred\u{001B}[0m\u{0085} mid\u{202E}\u{2066}\u{200B}\u{FEFF}\u{00AD} ăș end"
        #expect(Redaction.sanitizeText(unsafe) == "startred mid ăș end")
        #expect(Redaction.sanitizeText("ordinary text ă ș") == "ordinary text ă ș")
    }
}
