///
/// Copyright (c) 2016 Dropbox, Inc. All rights reserved.
///

import SystemConfiguration
import Foundation

public protocol SharedApplication: class {
    func presentErrorMessage(_ message: String, title: String)
    func presentErrorMessageWithHandlers(_ message: String, title: String, buttonHandlers: Dictionary<String, () -> Void>)
    func presentPlatformSpecificAuth(_ authURL: URL) -> Bool
    func presentAuthChannel(_ authURL: URL, tryIntercept: @escaping ((URL) -> Bool), cancelHandler: @escaping (() -> Void))
    func presentExternalApp(_ url: URL)
    func canPresentExternalApp(_ url: URL) -> Bool
    func presentLoading()
    func dismissLoading()
}

public typealias DropboxOAuthCompletion = (DropboxOAuthResult?) -> Void

/// Manages access token storage and authentication
///
/// Use the `DropboxOAuthManager` to authenticate users through OAuth2, save access tokens, and retrieve access tokens.
///
/// @note OAuth flow webviews localize to enviroment locale.
///
open class DropboxOAuthManager {
    public let locale: Locale?
    let appKey: String
    let redirectURL: URL
    let host: String
    var urls: Array<URL>
    /// Session data for OAuth2 code flow with PKCE.
    /// nil if we are in the legacy token flow.
    var authSession: AuthSession?
    weak var sharedApplication: SharedApplication?

    private var localeIdentifier: String {
        return locale?.identifier ?? (Bundle.main.preferredLocalizations.first ?? "en")
    }

    // MARK: Shared instance
    /// A shared instance of a `DropboxOAuthManager` for convenience
    public static var sharedOAuthManager: DropboxOAuthManager!

    // MARK: Functions
    public init(appKey: String, host: String) {
        self.appKey = appKey
        self.redirectURL = URL(string: "db-\(self.appKey)://2/token")!
        self.host = host
        self.urls = [self.redirectURL]
        self.locale = nil;
    }

    ///
    /// Create an instance
    /// parameter appKey: The app key from the developer console that identifies this app.
    ///
    convenience public init(appKey: String) {
        self.init(appKey: appKey, host: "www.dropbox.com")
    }

    ///
    /// Try to handle a redirect back into the application
    ///
    /// - parameter url: The URL to attempt to handle
    ///
    /// - returns `nil` if SwiftyDropbox cannot handle the redirect URL, otherwise returns the `DropboxOAuthResult`.
    ///
    open func handleRedirectURL(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        // check if url is a cancel url
        if (url.host == "1" && url.path == "/cancel") || (url.host == "2" && url.path == "/cancel") {
            completion(.cancel)
        } else if !self.canHandleURL(url) {
            completion(nil)
        } else {
            extractFromUrl(url) { result in
                if let result = result {
                    switch result {
                    case .success(let token):
                        _ = self.storeAccessToken(token)
                    default:
                        break
                    }
                }
                completion(result)
            }
        }
    }

    ///
    /// Present the OAuth2 authorization request page by presenting a web view controller modally.
    ///
    /// - parameters:
    ///     - controller: The controller to present from.
    ///     - usePKCE: Whether to use OAuth2 code flow with PKCE. Default is false, i.e. use the legacy token flow.
    ///     - scopeRequest: The ScopeRequest, only used in code flow with PKCE.
    open func authorizeFromSharedApplication(
        _ sharedApplication: SharedApplication, usePKCE: Bool = false, scopeRequest: ScopeRequest? = nil) {
        let cancelHandler: (() -> Void) = {
            let cancelUrl = URL(string: "db-\(self.appKey)://2/cancel")!
            sharedApplication.presentExternalApp(cancelUrl)
        }

        if !Reachability.connectedToNetwork() {
            let message = "Try again once you have an internet connection"
            let title = "No internet connection"

            let buttonHandlers: [String: () -> Void] = [
                "Cancel": { cancelHandler() },
                "Retry": { self.authorizeFromSharedApplication(sharedApplication, usePKCE: usePKCE, scopeRequest: scopeRequest) },
            ]
            sharedApplication.presentErrorMessageWithHandlers(message, title: title, buttonHandlers: buttonHandlers)

            return
        }

        if !self.conformsToAppScheme() {
            let message = "DropboxSDK: unable to link; app isn't registered for correct URL scheme (db-\(self.appKey)). Add this scheme to your project Info.plist file, under \"URL types\" > \"URL Schemes\"."
            let title = "SwiftyDropbox Error"

            sharedApplication.presentErrorMessage(message, title:title)

            return
        }

        if usePKCE {
            authSession = AuthSession(scopeRequest: scopeRequest)
        } else {
            authSession = nil
        }
        self.sharedApplication = sharedApplication

        let url = self.authURL()

        if checkAndPresentPlatformSpecificAuth(sharedApplication) {
            return
        }

        let tryIntercept: ((URL) -> Bool) = { url in
            if self.canHandleURL(url) {
                sharedApplication.presentExternalApp(url)
                return true
            } else {
                return false
            }
        }
        sharedApplication.presentAuthChannel(url, tryIntercept: tryIntercept, cancelHandler: cancelHandler)
    }

    fileprivate func conformsToAppScheme() -> Bool {
        let appScheme = "db-\(self.appKey)"

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [ [String: AnyObject] ] ?? []

        for urlType in urlTypes {
            let schemes = urlType["CFBundleURLSchemes"] as? [String] ?? []
            for scheme in schemes {
                if scheme == appScheme {
                    return true
                }
            }
        }
        return false
    }

    func authURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth2/authorize"

        var params = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "locale", value: localeIdentifier),
            URLQueryItem(name: "disable_signup", value: "true"),
        ]

        let state: String
        if let authSession = authSession {
            // Code flow.
            state = authSession.state
            params.append(contentsOf: OAuthUtils.createPkceCodeFlowParams(for: authSession))
        } else {
            // Token flow.
            state = ProcessInfo.processInfo.globallyUniqueString
            params.append(contentsOf: [
                URLQueryItem(name: OAuthConstants.responseTypeKey, value: "token"),
                URLQueryItem(name: OAuthConstants.stateKey, value: state),
            ])
        }
        UserDefaults.standard.setValue(state, forKey: Constants.kCSRFKey)
        components.queryItems = params
        return components.url!
    }

    fileprivate func canHandleURL(_ url: URL) -> Bool {
        for known in self.urls {
            if url.scheme == known.scheme && url.host == known.host && url.path == known.path {
                return true
            }
        }
        return false
    }

    func extractFromRedirectURL(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        let results = OAuthUtils.extractParamsFromUrl(url)
        if let error = results["error"] {
            let result: DropboxOAuthResult
            let desc = results[OAuthConstants.errorDescription]?
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            if results[OAuthConstants.errorKey] != "access_denied" {
                result = .cancel
            } else {
                result = .error(OAuth2Error(errorCode: error), desc ?? "")
            }
            completion(result)
        } else {
            let state = results[OAuthConstants.stateKey]
            let storedState = UserDefaults.standard.string(forKey: Constants.kCSRFKey)

            if state == nil || storedState == nil || state != storedState {
                completion(.error(
                    OAuth2Error(errorCode: "inconsistent_state"), "Auth flow failed because of inconsistent state.")
                )
            } else {
                // reset upon success
                UserDefaults.standard.setValue(nil, forKey: Constants.kCSRFKey)
                if let authSession = authSession, let authCode = results["code"] {
                    // Code flow.
                    finishPkceOAuth(
                        authCode: authCode, codeVerifier: authSession.pkceData.codeVerifier, completion: completion
                    )
                } else if let accessToken = results["access_token"], let uid = results[OAuthConstants.uidKey] {
                    // Token flow.
                    completion(.success(DropboxAccessToken(accessToken: accessToken, uid: uid)))
                } else {
                    completion(.error(.unknown, "Invalid response."))
                }
            }
        }
    }

    func extractFromUrl(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        return extractFromRedirectURL(url, completion: completion)
    }

    func finishPkceOAuth(authCode: String, codeVerifier: String, completion: @escaping DropboxOAuthCompletion) {
        sharedApplication?.presentLoading()
        let request = OAuthTokenExchangeRequest(
            oauthCode: authCode, codeVerifier: codeVerifier,
            appKey: appKey, locale: localeIdentifier, redirectUri: redirectURL.absoluteString
        )
        request.start { [weak sharedApplication] in
            sharedApplication?.dismissLoading()
            completion($0)
        }
    }

    func checkAndPresentPlatformSpecificAuth(_ sharedApplication: SharedApplication) -> Bool {
        return false
    }

    ///
    /// Retrieve all stored access tokens
    ///
    /// - returns: a dictionary mapping users to their access tokens
    ///
    open func getAllAccessTokens() -> [String : DropboxAccessToken] {
        let users = Keychain.getAll()
        var ret = [String : DropboxAccessToken]()
        for user in users {
            if let accessToken = Keychain.get(user) {
                ret[user] = accessToken
            }
        }
        return ret
    }

    ///
    /// Check if there are any stored access tokens
    ///
    /// - returns: Whether there are stored access tokens
    ///
    open func hasStoredAccessTokens() -> Bool {
        return self.getAllAccessTokens().count != 0
    }

    ///
    /// Retrieve the access token for a particular user
    ///
    /// - parameter user: The user whose token to retrieve
    ///
    /// - returns: An access token if present, otherwise `nil`.
    ///
    open func getAccessToken(_ user: String?) -> DropboxAccessToken? {
        if let user = user {
            return Keychain.get(user)
        }
        return nil
    }

    ///
    /// Delete a specific access token
    ///
    /// - parameter token: The access token to delete
    ///
    /// - returns: whether the operation succeeded
    ///
    open func clearStoredAccessToken(_ token: DropboxAccessToken) -> Bool {
        return Keychain.delete(token.uid)
    }

    ///
    /// Delete all stored access tokens
    ///
    /// - returns: whether the operation succeeded
    ///
    open func clearStoredAccessTokens() -> Bool {
        return Keychain.clear()
    }

    ///
    /// Save an access token
    ///
    /// - parameter token: The access token to save
    ///
    /// - returns: whether the operation succeeded
    ///
    open func storeAccessToken(_ token: DropboxAccessToken) -> Bool {
        do {
            let jsonEncoder = JSONEncoder()
            let data = try jsonEncoder.encode(token)
            return Keychain.set(token.uid, value: data)
        } catch {
            return false
        }
    }

    ///
    /// Utility function to return an arbitrary access token
    ///
    /// - returns: the "first" access token found, if any (otherwise `nil`)
    ///
    open func getFirstAccessToken() -> DropboxAccessToken? {
        return self.getAllAccessTokens().values.first
    }
}

/// A Dropbox access token
open class DropboxAccessToken: CustomStringConvertible, Codable {

    /// The access token string.
    public let accessToken: String

    /// The associated user id.
    public let uid: String

    /// The refresh token if accessToken is short-lived.
    public let refreshToken: String?

    /// The expiration time of the (short-lived) accessToken.
    public let tokenExpirationTimestamp: TimeInterval?

    /// Designated Initializer
    ///
    /// - parameters:
    ///     - accessToken: The access token string.
    ///     - uid: The associated user id.
    ///     - refreshToken: The refresh token if accessToken is short-lived.
    ///     - tokenExpirationTimestamp: The expiration time of the (short-lived) accessToken.
    init(
        accessToken: String, uid: String,
        refreshToken: String? = nil, tokenExpirationTimestamp: TimeInterval? = nil
    ) {
        self.accessToken = accessToken
        self.uid = uid
        self.refreshToken = refreshToken
        self.tokenExpirationTimestamp = tokenExpirationTimestamp
    }

    open var description: String {
        return self.accessToken
    }
}

/// A failed authorization.
/// See RFC6749 4.2.2.1
public enum OAuth2Error {
    /// The client is not authorized to request an access token using this method.
    case unauthorizedClient

    /// The resource owner or authorization server denied the request.
    case accessDenied

    /// The authorization server does not support obtaining an access token using this method.
    case unsupportedResponseType

    /// The requested scope is invalid, unknown, or malformed.
    case invalidScope

    /// The authorization server encountered an unexpected condition that prevented it from fulfilling the request.
    case serverError

    /// The authorization server is currently unable to handle the request due to a temporary overloading or maintenance of the server.
    case temporarilyUnavailable

    /// The state param received from the authorization server does not match the state param stored by the SDK.
    case inconsistentState

    /// Some other error (outside of the OAuth2 specification)
    case unknown

    /// Initializes an error code from the string specced in RFC6749
    init(errorCode: String) {
        switch errorCode {
            case "unauthorized_client": self = .unauthorizedClient
            case "access_denied": self = .accessDenied
            case "unsupported_response_type": self = .unsupportedResponseType
            case "invalid_scope": self = .invalidScope
            case "server_error": self = .serverError
            case "temporarily_unavailable": self = .temporarilyUnavailable
            case "inconsistent_state": self = .inconsistentState
            default: self = .unknown
        }
    }
}

internal let kDBLinkNonce = "dropbox.sync.nonce"

/// The result of an authorization attempt.
public enum DropboxOAuthResult {
    /// The authorization succeeded. Includes a `DropboxAccessToken`.
    case success(DropboxAccessToken)

    /// The authorization failed. Includes an `OAuth2Error` and a descriptive message.
    case error(OAuth2Error, String)

    /// The authorization was manually canceled by the user.
    case cancel
}

class Keychain {
    static let checkAccessibilityMigrationOneTime: () = {
       Keychain.checkAccessibilityMigration()
    }()

    class func queryWithDict(_ query: [String : AnyObject]) -> CFDictionary {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        var queryDict = query

        queryDict[kSecClass as String]       = kSecClassGenericPassword
        queryDict[kSecAttrService as String] = "\(bundleId).dropbox.authv2" as AnyObject?
        queryDict[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return queryDict as CFDictionary
    }

    class func set(_ key: String, value: String) -> Bool {
        if let data = value.data(using: String.Encoding.utf8) {
            return set(key, value: data)
        } else {
            return false
        }
    }

    class func set(_ key: String, value: Data) -> Bool {
        let query = Keychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject,
            (  kSecValueData as String): value as AnyObject
        ])

        SecItemDelete(query)

        return SecItemAdd(query, nil) == noErr
    }

    class func getAsData(_ key: String) -> Data? {
        let query = Keychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject,
            ( kSecReturnData as String): kCFBooleanTrue,
            ( kSecMatchLimit as String): kSecMatchLimitOne
        ])

        var dataResult: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataResult)

        if status == noErr {
            return dataResult as? Data
        }

        return nil
    }

    class func getAll() -> [String] {
        let query = Keychain.queryWithDict([
            ( kSecReturnAttributes as String): kCFBooleanTrue,
            (       kSecMatchLimit as String): kSecMatchLimitAll
        ])

        var dataResult: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataResult)

        if status == noErr {
            let results = dataResult as? [[String : AnyObject]] ?? []
            return results.map { d in d["acct"] as! String }

        }
        return []
    }

    class func get(_ key: String) -> DropboxAccessToken? {
        if let data = getAsData(key) {
            do {
                let jsonDecoder = JSONDecoder()
                return try jsonDecoder.decode(DropboxAccessToken.self, from: data)
            } catch {
                // The token might be stored as a string by a previous version of SDK.
                if let accessTokenString = String(data: data, encoding: .utf8) {
                    return DropboxAccessToken(accessToken: accessTokenString, uid: key)
                } else {
                    return nil
                }
            }
        } else {
            return nil
        }
    }

    class func delete(_ key: String) -> Bool {
        let query = Keychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject
        ])

        return SecItemDelete(query) == noErr
    }

    class func clear() -> Bool {
        let query = Keychain.queryWithDict([:])
        return SecItemDelete(query) == noErr
    }

    class func checkAccessibilityMigration() {
        let kAccessibilityMigrationOccurredKey = "KeychainAccessibilityMigration"
        let MigrationOccurred = UserDefaults.standard.string(forKey: kAccessibilityMigrationOccurredKey)

        if (MigrationOccurred != "true") {
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            let queryDict = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(bundleId).dropbox.authv2" as AnyObject?]
            let attributesToUpdateDict = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            SecItemUpdate(queryDict as CFDictionary, attributesToUpdateDict as CFDictionary)
            UserDefaults.standard.set("true", forKey: kAccessibilityMigrationOccurredKey)
        }
    }
}

class Reachability {
    /// From http://stackoverflow.com/questions/25623272/how-to-use-scnetworkreachability-in-swift/25623647#25623647.
    ///
    /// This method uses `SCNetworkReachabilityCreateWithAddress` to create a reference to monitor the example host
    /// defined by our zeroed `zeroAddress` struct. From this reference, we can extract status flags regarding the
    /// reachability of this host, using `SCNetworkReachabilityGetFlags`.

    class func connectedToNetwork() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else {
            return false
        }

        var flags: SCNetworkReachabilityFlags = []
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
            return false
        }

        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return (isReachable && !needsConnection)
    }
}
