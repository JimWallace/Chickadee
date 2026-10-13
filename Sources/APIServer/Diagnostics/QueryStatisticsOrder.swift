/// How `get_query_stats` orders the statements.
enum QueryStatisticsOrder: String, CaseIterable, Sendable {
    /// Total time over all calls: where the database spends its time.
    case total
    /// Mean time per call: the slowest single statements.
    case mean
    /// Number of calls: the statements that run most often.
    case calls

    /// The `pg_stat_statements` column to sort by. A closed set, so it is
    /// safe to put in the SQL text.
    var column: String {
        switch self {
        case .total: return "total_exec_time"
        case .mean: return "mean_exec_time"
        case .calls: return "calls"
        }
    }
}
