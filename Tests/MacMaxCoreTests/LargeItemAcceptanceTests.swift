import Testing
@testable import MacMaxCore

@Suite("Large item acceptance")
struct LargeItemAcceptanceTests {
    @Test("du entries are validated, converted to bytes, sorted, and limited")
    func validatesSortsAndLimits() {
        let du = """
            8	/h/tie-b
            8	/h/tie-a
            9	/h/largest
            7	/h/below
            100	/h
            10	relative/item
            -1	/h/negative
            nope	/h/not-a-number
            12 /h/no-tab
            9223372036854775807	/h/overflow
            """

        let selected = LargeItemSelection.select(du: du, root: "/h", minBytes: 8 * 1024, limit: 2)

        #expect(selected.map(\.path) == ["/h/largest", "/h/tie-a"])
        #expect(selected.map(\.bytes) == [Int64(9 * 1024), Int64(8 * 1024)])
    }

    @Test("A big ancestor is replaced by its deepest big descendant")
    func selectsDeepestBigEntry() {
        let du = """
            10485760	/h/Library
            9437184	/h/Library/Caches
            """

        let selected = LargeItemSelection.select(du: du, root: "/h", minBytes: 1024, limit: 10)

        #expect(selected.map(\.path) == ["/h/Library/Caches"])
    }

    @Test("Big siblings remain while their big parent is removed")
    func keepsSiblingLeaves() {
        let du = """
            300	/h/parent
            120	/h/parent/alpha
            180	/h/parent/beta
            """

        let selected = LargeItemSelection.select(du: du, root: "/h", minBytes: 100 * 1024, limit: 10)

        #expect(selected.map(\.path) == ["/h/parent/beta", "/h/parent/alpha"])
    }

    @Test("A matching name prefix is not path containment")
    func distinguishesPathComponentsFromPrefixes() {
        let du = """
            200	/h/ab
            300	/h/abc/item
            """

        let selected = LargeItemSelection.select(du: du, root: "/h", minBytes: 1, limit: 10)

        #expect(selected.map(\.path) == ["/h/abc/item", "/h/ab"])
    }
}
