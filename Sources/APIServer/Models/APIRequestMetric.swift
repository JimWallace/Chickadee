import Fluent
import Vapor

final class APIRequestMetric: Model, Content, @unchecked Sendable {
    static let schema = "request_metrics"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "method")
    var method: String

    @Field(key: "path")
    var path: String

    @OptionalField(key: "request_kind")
    var requestKind: String?

    @Field(key: "status_code")
    var statusCode: Int

    @Field(key: "started_at")
    var startedAt: Date

    @Field(key: "finished_at")
    var finishedAt: Date

    @Field(key: "duration_ms")
    var durationMs: Int

    @OptionalField(key: "submission_id")
    var submissionID: String?

    @OptionalField(key: "worker_id")
    var workerID: String?

    init() {}

    init(
        id: UUID? = nil,
        method: String,
        path: String,
        requestKind: String?,
        statusCode: Int,
        startedAt: Date,
        finishedAt: Date,
        durationMs: Int,
        submissionID: String?,
        workerID: String?
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.requestKind = requestKind
        self.statusCode = statusCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.submissionID = submissionID
        self.workerID = workerID
    }
}
