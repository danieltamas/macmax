import Testing
@testable import MacMaxCore

private func row(
    _ id: String,
    _ name: String,
    kind: AppKind = .app,
    pids: [Int32] = [],
    cpu: Double? = nil,
    memory: UInt64? = nil,
    disk: Double? = nil,
    network: Double? = nil
) -> AppRow {
    AppRow(
        id: id,
        name: name,
        bundleID: "com.example.\(id)",
        kind: kind,
        pids: pids,
        processCount: max(1, pids.count),
        cpuPercent: cpu,
        footprintBytes: memory,
        diskBytesPerSecond: disk,
        networkBytesPerSecond: network
    )
}

@Test("Apps sort descending by every measure")
func appsSortDescendingByEveryMeasure() {
    let rows = [
        row("low", "Low App", cpu: 1, memory: 10, disk: 100, network: 1_000),
        row("middle", "Middle App", cpu: 2, memory: 20, disk: 200, network: 2_000),
        row("high", "High App", cpu: 3, memory: 30, disk: 300, network: 3_000),
    ]

    for sort in AppSort.allCases {
        #expect(AppListing.sorted(rows, by: sort).map(\.id) == ["high", "middle", "low"])
    }
}

@Test("Nil and NaN measures sort last by case-insensitive name then id")
func unknownMeasuresSortLastDeterministically() {
    let rows = [
        row("z", "Zulu", cpu: nil),
        row("b", "example app", cpu: .nan),
        row("a", "Example App", cpu: nil),
        row("measured", "Measured", cpu: 0.5),
    ]

    #expect(AppListing.sorted(rows, by: .cpu).map(\.id) == ["measured", "a", "b", "z"])
}

@Test("Ties have a stable order independent of input permutation")
func tiedSortIsPermutationIndependent() {
    let rows = [
        row("z", "Beta", cpu: 5),
        row("b", "example app", cpu: 5),
        row("a", "Example App", cpu: 5),
        row("c", "Alpha", cpu: 5),
    ]
    let expected = ["c", "z", "a", "b"]

    #expect(AppListing.sorted(rows, by: .cpu).map(\.id) == expected)
    #expect(AppListing.sorted(rows.reversed(), by: .cpu).map(\.id) == expected)
    for _ in 0..<20 {
        #expect(AppListing.sorted(rows.shuffled(), by: .cpu).map(\.id) == expected)
    }
}

@Test("Every app kind filter keeps only its matching rows and preserves order")
func filtersEveryAppKind() {
    let rows = [
        row("app", "Example App", kind: .app),
        row("background", "Example Helper", kind: .background),
        row("claude", "Example Agent", kind: .claudeCode),
        row("docker", "Example Container", kind: .docker),
    ]
    let expectations: [(AppFilter, [String])] = [
        (.all, ["app", "background", "claude", "docker"]),
        (.apps, ["app"]),
        (.background, ["background"]),
        (.claudeCode, ["claude"]),
        (.docker, ["docker"]),
    ]

    for (filter, ids) in expectations {
        #expect(AppListing.filtered(rows, filter: filter, query: "").map(\.id) == ids)
    }
}

@Test("Search trims and matches name or bundle id case-insensitively")
func searchMatchesNameAndBundleID() {
    let rows = [
        AppRow(id: "one", name: "Example App", bundleID: "org.example.product"),
        AppRow(id: "two", name: "Sample Tool", bundleID: "org.sample.tool"),
    ]

    #expect(AppListing.filtered(rows, filter: .all, query: "  EXAMPLE app ").map(\.id) == ["one"])
    #expect(AppListing.filtered(rows, filter: .all, query: "EXAMPLE.PROD").map(\.id) == ["one"])
    #expect(AppListing.filtered(rows, filter: .all, query: "   ").map(\.id) == ["one", "two"])
}

@Test("PID search requires an exact decimal match")
func pidSearchIsExact() {
    let rows = [
        row("exact", "Example App", pids: [123, 456]),
        row("substring", "Other App", pids: [12_345]),
    ]

    #expect(AppListing.filtered(rows, filter: .all, query: "123").map(\.id) == ["exact"])
    #expect(AppListing.filtered(rows, filter: .all, query: "23").isEmpty)
}

@Test("Kind and query filters are both applied")
func kindAndQueryCompose() {
    let rows = [
        row("app", "Example App", kind: .app),
        row("helper", "Example Helper", kind: .background),
    ]
    #expect(AppListing.filtered(rows, filter: .apps, query: "example").map(\.id) == ["app"])
}

@Test("Pages expose the requested prefix and a remaining count in groups of 25")
func pageBoundaries() {
    let rows = (0..<51).map { row("app-\($0)", "Example App \($0)") }

    #expect(AppListing.pageSize == 25)
    #expect(AppListing.page(rows, shown: -1).visible.isEmpty)
    #expect(AppListing.page(rows, shown: -1).remaining == 51)
    #expect(AppListing.page(rows, shown: 0).remaining == 51)
    #expect(AppListing.page(rows, shown: 25).visible == Array(rows.prefix(25)))
    #expect(AppListing.page(rows, shown: 25).remaining == 26)
    #expect(AppListing.page(rows, shown: 50).remaining == 1)
    #expect(AppListing.page(rows, shown: 75).visible == rows)
    #expect(AppListing.page(rows, shown: 75).remaining == 0)
}
