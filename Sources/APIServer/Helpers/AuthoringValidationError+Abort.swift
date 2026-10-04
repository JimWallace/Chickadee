// APIServer/Helpers/AuthoringValidationError+Abort.swift
//
// Lets an authoring-rule error leave a route or an MCP tool as a 422, the
// status the validators' `Abort`s carried.

import Vapor

extension AuthoringValidationError: AbortError {
    var status: HTTPResponseStatus { .unprocessableEntity }
    var reason: String { description }
}
