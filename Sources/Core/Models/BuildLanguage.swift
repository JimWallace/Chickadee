// Core/Models/BuildLanguage.swift

/// Programming languages supported by the build system.
public enum BuildLanguage: String, Codable, Sendable {
    case python
    case jupyter   // Jupyter Notebook (.ipynb)
}

