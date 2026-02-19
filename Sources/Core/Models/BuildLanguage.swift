// Core/Models/BuildLanguage.swift

/// Programming languages supported by the build system.
enum BuildLanguage: String, Codable, Sendable {
    case python
    case jupyter   // Jupyter Notebook (.ipynb)
}
