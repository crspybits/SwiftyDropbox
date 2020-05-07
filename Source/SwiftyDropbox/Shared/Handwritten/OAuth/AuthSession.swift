///
/// Copyright (c) 2020 Dropbox, Inc. All rights reserved.
///

import Foundation
import CommonCrypto

// MARK: Public

/// Struct contains the information of a requested scopes.
public struct ScopeRequest {
    /// Type of the requested scopes.
    public enum ScopeType: String {
        case team
        case user
    }

    let scopes: [String]
    let includeGrantedScopes: Bool
    let scopeType: ScopeType

    var scopeString: String? {
        guard !scopes.isEmpty else { return nil }
        return scopes.joined(separator: " ")
    }

    /// Designated Initializer.
    ///
    /// - Parameters:
    ///     - scopeType: Type of the requested scopes.
    ///     - scopes: A list of scope returned by Dropbox server. Each scope correspond to a group of API endpoints.
    ///       To call one API endpoint you have to obtains the scope first otherwise you will get HTTP 401.
    ///     - includeGrantedScopes: If false, Dropbox will give you the scopes in scopes array.
    ///       Otherwise Dropbox server will return a token with all scopes user previously granted your app
    ///       together with the new scopes.
    public init(scopeType: ScopeType, scopes: [String], includeGrantedScopes: Bool) {
        self.scopeType = scopeType
        self.scopes = scopes
        self.includeGrantedScopes = includeGrantedScopes
    }
}

// MARK: Internal

/// Object that contains all the necessary data of an OAuth 2 Authorization Code Flow with PKCE.s
struct AuthSession {
    let scopeRequest: ScopeRequest?
    let pkceData: PkceData
    let state: String
    let tokenAccessType = "offline"
    let responseType = "code"

    init(scopeRequest: ScopeRequest?) {
        self.pkceData = PkceData()
        self.scopeRequest = scopeRequest
        self.state = Self.createState(with: pkceData, scopeRequest: scopeRequest, tokenAccessType: tokenAccessType)
    }

    private static func createState(
        with pkceData: PkceData, scopeRequest: ScopeRequest?, tokenAccessType: String
    ) -> String {
        let codeChallenge = pkceData.codeChallenge
        var state = "oauth2code:\(codeChallenge):\(pkceData.codeChallengeMethod):\(tokenAccessType)"
        if let scopeRequest = scopeRequest {
            if let scopeString = scopeRequest.scopeString {
                state += ":\(scopeString)"
            }
            if scopeRequest.includeGrantedScopes {
                state += ":\(scopeRequest.scopeType.rawValue)"
            }
        }
        return state
    }
}

/// PKCE data for OAuth 2 Authorization Code Flow.
struct PkceData {
    let codeVerifier: String
    let codeChallenge: String
    let codeChallengeMethod = "S256"

    init() {
        self.codeVerifier = Self.randomStringOfLength(128)
        self.codeChallenge = Self.codeChallengeFromCodeVerifier(codeVerifier)
    }

    private static func randomStringOfLength(_ length: Int) -> String {
        let alphanumerics = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in alphanumerics.randomElement()! })
    }

    private static func codeChallengeFromCodeVerifier(_ codeVerifier: String) -> String {
        let data = codeVerifier.data(using: .ascii)!
        var digest = [UInt8](repeating: 0, count:Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes {
            CC_SHA256($0.baseAddress, UInt32(data.count), &digest)
        }
        /// Replace these characters to make the string safe to use in a URL.
        return Data(bytes: digest).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
