import Testing

@testable import APIServer

@Suite struct QueryStatisticsTests {
    @Test(arguments: [
        (QueryStatisticsOrder.total, "total_exec_time"),
        (.mean, "mean_exec_time"),
        (.calls, "calls"),
    ])
    func orderSortsByItsColumn(order: QueryStatisticsOrder, column: String) {
        #expect(order.column == column)
    }

    @Test func toolIsRegistered() {
        #expect(AdminMCPToolCatalog.live.all.contains { $0.name == GetQueryStatsTool.name })
    }

    @Test func orderDefaultsToTotalTime() throws {
        #expect(try GetQueryStatsTool.resolveOrder(nil) == .total)
        #expect(try GetQueryStatsTool.resolveOrder("mean") == .mean)
    }

    @Test func everyUnavailableStateTellsTheOperatorWhatToDo() {
        for state in [QueryStatistics.Availability.notPostgres, .notPreloaded, .extensionMissing] {
            #expect(state.note?.isEmpty == false)
        }
        #expect(QueryStatistics.Availability.ready.note == nil)
    }

    @Test func statementRoundsToTwoDecimalsAndComputesCacheHits() {
        let stat = QueryStatementStat(
            queryID: "42", query: "SELECT $1", calls: 3, totalMs: 10.12345, meanMs: 3.37448,
            maxMs: 5.0, rows: 3, sharedBlocksHit: 3, sharedBlocksRead: 1)
        #expect(stat.totalMs == 10.12)
        #expect(stat.meanMs == 3.37)
        #expect(stat.cacheHitPercent == 75)
    }

    @Test func statementWithNoBlockReadsHasNoCacheRate() {
        let stat = QueryStatementStat(
            queryID: "1", query: "SELECT 1", calls: 1, totalMs: 0.01, meanMs: 0.01,
            maxMs: 0.01, rows: 1, sharedBlocksHit: 0, sharedBlocksRead: 0)
        #expect(stat.cacheHitPercent == nil)
    }

    @Test func shareOfTotalIsAPercentOfAllTime() {
        let stat = QueryStatementStat(
            queryID: "7", query: "SELECT $1", calls: 1, totalMs: 25, meanMs: 25,
            maxMs: 25, rows: 1, sharedBlocksHit: 1, sharedBlocksRead: 0)
        #expect(GetQueryStatsTool.Statement(stat, totalExecMs: 100).shareOfTotalPercent == 25)
        #expect(GetQueryStatsTool.Statement(stat, totalExecMs: 0).shareOfTotalPercent == nil)
    }
}
