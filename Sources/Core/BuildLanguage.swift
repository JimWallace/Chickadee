// Core/Models/BuildLanguage.swift
//
// Represents the programming language for a submission.

/// Programming language supported by the build system.
public enum BuildLanguage: String, Codable, Sendable {
    case java
    case python
}
