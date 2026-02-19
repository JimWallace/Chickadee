// APIServer/routes.swift

import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: ResultRoutes())
}
