// APIServer/Helpers/Request+UnreadableEditorPayload.swift
//
// The reason an authoring editor shows when the server cannot decode the body
// it sent (UI audit #3007, finding 7). The decoder's own error names Swift
// types and coding paths; it goes to the log, and the editor says what to do.

import Vapor

/// Logs `error` and returns the sentence the editor shows.
func unreadableEditorPayload(_ req: Request, _ error: any Error) -> String {
    req.logger.warning("Editor payload could not be decoded: \(error)")
    return "the editor sent a change the server could not read. Reload the page and try again."
}
