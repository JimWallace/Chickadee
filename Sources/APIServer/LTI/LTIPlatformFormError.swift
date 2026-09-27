// APIServer/LTI/LTIPlatformFormError.swift
//
// Why `LTIPlatformForm.validated()` refused a registration, with the one
// sentence the admin page shows for each case.

enum LTIPlatformFormError: Error, Equatable, Sendable {
    enum URLField: String, Sendable {
        case issuer = "Issuer"
        case authLoginURL = "OIDC authorization URL"
        case accessTokenURL = "Access token URL"
        case jwksURL = "Key set URL"
    }

    case missingDisplayName
    case missingClientID
    case missingDeploymentID
    case invalidURL(URLField)
    case insecureURL(URLField)
    case duplicate

    var message: String {
        switch self {
        case .missingDisplayName: "Enter a name for the platform."
        case .missingClientID: "Enter the client ID that the platform issued."
        case .missingDeploymentID: "Enter at least one deployment ID."
        case .invalidURL(let field): "\(field.rawValue) must be an absolute URL."
        case .insecureURL(let field): "\(field.rawValue) must use https."
        case .duplicate: "A platform with this issuer and client ID is already registered."
        }
    }
}
