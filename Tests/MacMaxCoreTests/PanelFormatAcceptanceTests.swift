import Testing
@testable import MacMaxCore

@Test("Byte formatting uses the specified compact binary units")
func compactByteExamples() {
    #expect(CompactFormat.bytes(0) == "0 B")
    #expect(CompactFormat.bytes(1_023) == "1023 B")
    #expect(CompactFormat.bytes(1_536) == "1.5 KB")
    #expect(CompactFormat.bytes(812 * 1_024) == "812 KB")
    #expect(CompactFormat.bytes(UInt64(3.4 * 1_024 * 1_024 * 1_024)) == "3.4 GB")
    #expect(CompactFormat.bytes(12 * 1_024 * 1_024 * 1_024) == "12 GB")
}

@Test("Byte formatting handles UInt64 max without trapping")
func compactBytesHandlesExtreme() {
    let formatted = CompactFormat.bytes(.max)
    #expect(formatted.hasSuffix("EB") || formatted.hasSuffix("PB") || formatted.hasSuffix("TB"))
}

@Test("Rates append per second and reject non-finite or negative input")
func compactRateExamples() {
    #expect(CompactFormat.rate(1_536) == "1.5 KB/s")
    #expect(CompactFormat.rate(.nan) == "-")
    #expect(CompactFormat.rate(.infinity) == "-")
    #expect(CompactFormat.rate(-1) == "-")
    #expect(CompactFormat.rate(0) == "0 B/s")
}

@Test("Counts compact at thousands and millions and clamp negatives")
func compactCountExamples() {
    #expect(CompactFormat.count(999) == "999")
    #expect(CompactFormat.count(1_200) == "1.2K")
    #expect(CompactFormat.count(15_000) == "15K")
    #expect(CompactFormat.count(1_500_000) == "1.5M")
    #expect(CompactFormat.count(-1) == "0")
    _ = CompactFormat.count(.max)
}

@Test("Percents are whole, bounded in width and preserve unknown")
func compactPercentExamples() {
    #expect(CompactFormat.percent(34.4) == "34%")
    #expect(CompactFormat.percent(nil) == "-")
    #expect(CompactFormat.percent(.nan) == "-")
    #expect(CompactFormat.percent(.infinity) == "-")
    #expect(CompactFormat.percent(1_000) == "999%+")
    #expect(CompactFormat.percent(.greatestFiniteMagnitude).count <= 5)
}
