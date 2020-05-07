///
/// Copyright (c) 2020 Dropbox, Inc. All rights reserved.
///

import Foundation

enum OAuthUtils {
    static func createPkceCodeFlowParams(for authSession: AuthSession) -> [URLQueryItem] {
        var params = [URLQueryItem]()
        if let scopeString = authSession.scopeRequest?.scopeString {
            params.append(URLQueryItem(name: OAuthConstants.scopeKey, value: scopeString))
        }
        if let scopeRequest = authSession.scopeRequest, scopeRequest.includeGrantedScopes {
            params.append(
                URLQueryItem(name: OAuthConstants.includeGrantedScopesKey, value: scopeRequest.scopeType.rawValue)
            )
        }
        let pkceData = authSession.pkceData
        params.append(contentsOf: [
            URLQueryItem(name: OAuthConstants.codeChallengeKey, value: pkceData.codeChallenge),
            URLQueryItem(name: OAuthConstants.codeChallengeMethodKey, value: pkceData.codeChallengeMethod),
            URLQueryItem(name: OAuthConstants.tokenAccessTypeKey, value: authSession.tokenAccessType),
            URLQueryItem(name: OAuthConstants.responseTypeKey, value: authSession.responseType),
            URLQueryItem(name: OAuthConstants.stateKey, value: authSession.state),
        ])
        return params
    }
}
