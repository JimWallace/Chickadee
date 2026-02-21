// APIServer/routes.swift

import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: WebRoutes())
    try app.register(collection: ResultRoutes())
    try app.register(collection: SubmissionRoutes())
    try app.register(collection: SubmissionDownloadRoute())
    try app.register(collection: TestSetupRoutes())
    try app.register(collection: SubmissionQueryRoutes())
    try app.register(collection: BrowserResultRoutes())
}
