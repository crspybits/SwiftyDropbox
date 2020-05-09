///
/// Copyright (c) 2016 Dropbox, Inc. All rights reserved.
///

import Foundation
import SafariServices
import UIKit
import WebKit

/// Protocol for handling loading status during auth flow.
/// Implementing class could show custom UX to reflect loading status.
public protocol LoadingStatusDelegate: class {
    // Called when auth flow is loading/waiting for some data. e.g. Waiting for a network request to finish.
    func showLoading()
    // Called when auth flow finishes loading/waiting. e.g. A network request finished.
    func dismissLoading()
}

extension DropboxClientsManager {
    /// Starts a "token" flow.
    ///
    /// - Parameters:
    ///     - sharedApplication: The shared UIApplication instance in your app.
    ///     - controller: A UIViewController to present the auth flow from.
    ///     - openURL: Handler to open a URL.
    public static func authorizeFromController(_ sharedApplication: UIApplication, controller: UIViewController?, openURL: @escaping ((URL) -> Void)) {
        precondition(DropboxOAuthManager.sharedOAuthManager != nil, "Call `DropboxClientsManager.setupWithAppKey` or `DropboxClientsManager.setupWithTeamAppKey` before calling this method")
        let sharedMobileApplication = MobileSharedApplication(sharedApplication: sharedApplication, controller: controller, openURL: openURL)
        MobileSharedApplication.sharedMobileApplication = sharedMobileApplication
        DropboxOAuthManager.sharedOAuthManager.authorizeFromSharedApplication(sharedMobileApplication)
    }

    /// Starts the OAuth 2 Authorization Code Flow with PKCE.
    ///
    /// PKCE allows "authorization code" flow without "client_secret"
    /// It enables "native application", which is ensafe to hardcode client_secret in code, to use "authorization code".
    /// PKCE is more secure than "token" flow. If authorization code is compromised during
    /// transmission, it can't be used to exchange for access token without random generated
    /// code_verifier, which is stored inside this SDK.
    ///
    /// - Parameters:
    ///     - sharedApplication: The shared UIApplication instance in your app.
    ///     - controller: A UIViewController to present the auth flow from.
    ///     - loadingStatusDelegate: An optional delegate to handle loading experience during auth flow.
    ///       e.g. Show a looading spinner and block user interaction while loading/waiting.
    ///       If a delegate is not provided, the SDK will show a default loading spinner when necessary.
    ///     - openURL: Handler to open a URL.
    ///     - scopeRequest: Contains requested scopes to obtain.
    public static func authorizeFromControllerV2(
        _ sharedApplication: UIApplication, controller: UIViewController?, loadingStatusDelegate: LoadingStatusDelegate?, openURL: @escaping ((URL) -> Void), scopeRequest: ScopeRequest?
    ) {
        precondition(DropboxOAuthManager.sharedOAuthManager != nil, "Call `DropboxClientsManager.setupWithAppKey` or `DropboxClientsManager.setupWithTeamAppKey` before calling this method")
        let sharedMobileApplication = MobileSharedApplication(sharedApplication: sharedApplication, controller: controller, openURL: openURL)
        sharedMobileApplication.loadingStatusDelegate = loadingStatusDelegate
        MobileSharedApplication.sharedMobileApplication = sharedMobileApplication
        DropboxOAuthManager.sharedOAuthManager.authorizeFromSharedApplication(sharedMobileApplication, usePKCE: true, scopeRequest: scopeRequest)
    }

    public static func setupWithAppKey(_ appKey: String, transportClient: DropboxTransportClient? = nil) {
        setupWithOAuthManager(appKey, oAuthManager: DropboxMobileOAuthManager(appKey: appKey), transportClient: transportClient)
    }

    public static func setupWithAppKeyMultiUser(_ appKey: String, transportClient: DropboxTransportClient? = nil, tokenUid: String?) {
        setupWithOAuthManagerMultiUser(appKey, oAuthManager: DropboxMobileOAuthManager(appKey: appKey), transportClient: transportClient, tokenUid: tokenUid)
    }

    public static func setupWithTeamAppKey(_ appKey: String, transportClient: DropboxTransportClient? = nil) {
        setupWithOAuthManagerTeam(appKey, oAuthManager: DropboxMobileOAuthManager(appKey: appKey), transportClient: transportClient)
    }

    public static func setupWithTeamAppKeyMultiUser(_ appKey: String, transportClient: DropboxTransportClient? = nil, tokenUid: String?) {
        setupWithOAuthManagerMultiUserTeam(appKey, oAuthManager: DropboxMobileOAuthManager(appKey: appKey), transportClient: transportClient, tokenUid: tokenUid)
    }
}

open class DropboxMobileOAuthManager: DropboxOAuthManager {
    var dauthRedirectURL: URL
    
    public override init(appKey: String, host: String) {
        self.dauthRedirectURL = URL(string: "db-\(appKey)://1/connect")!
        super.init(appKey: appKey, host:host)
        self.urls.append(self.dauthRedirectURL)
    }

    internal override func extractFromUrl(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        if url.host == "1" { // dauth
            extractfromDAuthURL(url, completion: completion)
        } else {
            extractFromRedirectURL(url, completion: completion)
        }
    }
    
    internal override func checkAndPresentPlatformSpecificAuth(_ sharedApplication: SharedApplication) -> Bool {
        if !self.hasApplicationQueriesSchemes() {
            let message = "DropboxSDK: unable to link; app isn't registered to query for URL schemes dbapi-2 and dbapi-8-emm. Add a dbapi-2 entry and a dbapi-8-emm entry to LSApplicationQueriesSchemes"
            let title = "SwiftyDropbox Error"
            sharedApplication.presentErrorMessage(message, title: title)
            return true
        }
        
        if let scheme = dAuthScheme(sharedApplication) {
            let url: URL
            if let authSession = authSession {
                // Code flow
                url = dAuthURL(scheme, authSession: authSession)
            } else {
                // Token flow
                let nonce = UUID().uuidString
                UserDefaults.standard.set(nonce, forKey: kDBLinkNonce)
                UserDefaults.standard.synchronize()
                url = dAuthURL(scheme, nonce: nonce)
            }
            sharedApplication.presentExternalApp(url)
            return true
        }
        return false
    }
    
    open override func handleRedirectURL(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        super.handleRedirectURL(url, completion: {
            if let sharedMobileApplication = MobileSharedApplication.sharedMobileApplication {
                sharedMobileApplication.dismissAuthController()
            }
            completion($0)
        })
    }

    fileprivate func dAuthURL(_ scheme: String, nonce: String?) -> URL {
        var components = dauthUrlCommonComponents(with: scheme)
        if let n = nonce {
            let state = "oauth2:\(n)"
            components.queryItems?.append(URLQueryItem(name: OAuthConstants.stateKey, value: state))
        }
        return components.url!
    }

    private func dAuthURL(_ scheme: String, authSession: AuthSession) -> URL {
        var components = dauthUrlCommonComponents(with: scheme)
        let extraQueryParams = Self.createExtraQueryParamsString(for: authSession)
        components.queryItems?.append(contentsOf: [
            URLQueryItem(name: OAuthConstants.stateKey, value: authSession.state),
            URLQueryItem(name: OAuthConstants.extraQueryParamsKey, value: extraQueryParams),
        ])
        return components.url!
    }

    private func dauthUrlCommonComponents(with scheme: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "1"
        components.path = "/connect"
        components.queryItems = [
            URLQueryItem(name: "k", value: self.appKey),
            URLQueryItem(name: "s", value: ""),
        ]
        return components
    }
    
    fileprivate func dAuthScheme(_ sharedApplication: SharedApplication) -> String? {
        if sharedApplication.canPresentExternalApp(dAuthURL("dbapi-2", nonce: nil)) {
            return "dbapi-2"
        } else if sharedApplication.canPresentExternalApp(dAuthURL("dbapi-8-emm", nonce: nil)) {
            return "dbapi-8-emm"
        } else {
            return nil
        }
    }
    
    func extractfromDAuthURL(_ url: URL, completion: @escaping DropboxOAuthCompletion) {
        switch url.path {
        case "/connect":
            let results = OAuthUtils.extractParamsFromUrl(url)
            if let authSession = authSession {
                handleCodeFlowResults(results, authSession: authSession, completion: completion)
            } else {
                handleTokenFlowResults(results, completion: completion)
            }
        default:
            completion(.error(.accessDenied, "User cancelled Dropbox link"))
        }
    }

    private func handleCodeFlowResults(
        _ results: [String: String], authSession: AuthSession, completion: @escaping DropboxOAuthCompletion
    ) {
        let state = results[OAuthConstants.stateKey]
        guard state == authSession.state else {
            completion(.error(.unknown, "Unable to verify link request"))
            return
        }

        let authCode: String?
        if let code = results[OAuthConstants.oauthCodeKey] {
            authCode = code
        } else if results[OAuthConstants.oauthTokenKey] == "oauth2code:",
            let code = results[OAuthConstants.oauthSecretKey] {
            authCode = code
        } else {
            authCode = nil
        }
        if let authCode = authCode {
            finishPkceOAuth(
                authCode: authCode, codeVerifier: authSession.pkceData.codeVerifier, completion: completion
            )
        } else {
            completion(.error(.unknown, "Unable to verify link request"))
        }
    }

    private func handleTokenFlowResults(_ results: [String: String], completion: @escaping DropboxOAuthCompletion) {
        let state = results[OAuthConstants.stateKey]
        let result: DropboxOAuthResult
        if let nonce = UserDefaults.standard.object(forKey: kDBLinkNonce) as? String, state == "oauth2:\(nonce)",
            let accessToken = results[OAuthConstants.oauthSecretKey],
            let uid = results[OAuthConstants.uidKey] {
            result = .success(DropboxAccessToken(accessToken: accessToken, uid: uid))
        } else {
            result = .error(.unknown, "Unable to verify link request")
        }
        completion(result)
    }
    
    fileprivate func hasApplicationQueriesSchemes() -> Bool {
        let queriesSchemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        
        var foundApi2 = false
        var foundApi8Emm = false
        for scheme in queriesSchemes {
            if scheme == "dbapi-2" {
                foundApi2 = true
            } else if scheme == "dbapi-8-emm" {
                foundApi8Emm = true
            }
            if foundApi2 && foundApi8Emm {
                return true
            }
        }
        return false
    }

    /// Creates a string that contains all code flow query parameters.
    private static func createExtraQueryParamsString(for authSession: AuthSession) -> String {
        let pkceData = authSession.pkceData
        var extraQueryParams = "\(OAuthConstants.codeChallengeKey)=\(pkceData.codeChallenge)"
            + "&\(OAuthConstants.codeChallengeMethodKey)=\(pkceData.codeChallengeMethod)"
            + "&\(OAuthConstants.tokenAccessTypeKey)=\(authSession.tokenAccessType)"
            + "&\(OAuthConstants.responseTypeKey)=\(authSession.responseType)"
        if let scopeRequest = authSession.scopeRequest {
            if let scopeString = scopeRequest.scopeString {
                extraQueryParams += "&\(OAuthConstants.scopeKey)=\(scopeString)"
            }
            if scopeRequest.includeGrantedScopes {
                extraQueryParams += "&\(OAuthConstants.includeGrantedScopesKey)=\(scopeRequest.scopeType.rawValue)"
            }
        }
        return extraQueryParams
    }
}

open class MobileSharedApplication: SharedApplication {
    public static var sharedMobileApplication: MobileSharedApplication?

    let sharedApplication: UIApplication
    let controller: UIViewController?
    let openURL: ((URL) -> Void)

    weak var loadingStatusDelegate: LoadingStatusDelegate?

    public init(sharedApplication: UIApplication, controller: UIViewController?, openURL: @escaping ((URL) -> Void)) {
        // fields saved for app-extension safety
        self.sharedApplication = sharedApplication
        self.controller = controller
        self.openURL = openURL
    }

    open func presentErrorMessage(_ message: String, title: String) {
        let alertController = UIAlertController(
            title: title,
            message: message,
            preferredStyle: UIAlertController.Style.alert)
        if let controller = controller {
            controller.present(alertController, animated: true, completion: { fatalError(message) })
        }
    }

    open func presentErrorMessageWithHandlers(_ message: String, title: String, buttonHandlers: Dictionary<String, () -> Void>) {
        let alertController = UIAlertController(
            title: title,
            message: message,
            preferredStyle: UIAlertController.Style.alert)

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { (_) in
            if let handler = buttonHandlers["Cancel"] {
                handler()
            }
        })

        alertController.addAction(UIAlertAction(title: "Retry", style: .default) { (_) in
            if let handler = buttonHandlers["Retry"] {
                handler()
            }
        })

        if let controller = controller {
            controller.present(alertController, animated: true, completion: {})
        }
    }

    open func presentPlatformSpecificAuth(_ authURL: URL) -> Bool {
        presentExternalApp(authURL)
        return true
    }

    open func presentAuthChannel(_ authURL: URL, tryIntercept: @escaping ((URL) -> Bool), cancelHandler: @escaping (() -> Void)) {
        if let controller = self.controller {
            let safariViewController = MobileSafariViewController(url: authURL, cancelHandler: cancelHandler)
            controller.present(safariViewController, animated: true, completion: nil)
        }
    }

    open func presentExternalApp(_ url: URL) {
        self.openURL(url)
    }

    open func canPresentExternalApp(_ url: URL) -> Bool {
        return self.sharedApplication.canOpenURL(url)
    }

    open func dismissAuthController() {
        if let controller = self.controller {
            if let presentedViewController = controller.presentedViewController {
                if presentedViewController.isBeingDismissed == false && presentedViewController is MobileSafariViewController {
                    controller.dismiss(animated: true, completion: nil)
                }
            }
        }
    }

    public func presentLoading() {
        if let safariViewController = controller?.presentedViewController as? MobileSafariViewController {
            // Web OAuth flow, present the spinner over the MobileSafariViewController.
            safariViewController.present(LoadingViewController(nibName: nil, bundle: nil), animated: false)
        } else {
            if let loadingStatusDelegate = loadingStatusDelegate {
                loadingStatusDelegate.showLoading()
            } else {
                controller?.present(LoadingViewController(nibName: nil, bundle: nil), animated: false)
            }
        }
    }

    public func dismissLoading() {
        if let safariViewController = controller?.presentedViewController as? MobileSafariViewController,
            let loadingView = safariViewController.presentedViewController as? LoadingViewController {
            // Web OAuth flow, dismiss loading view on the MobileSafariViewController.
            loadingView.dismiss(animated: false)
        } else {
            if let loadingStatusDelegate = loadingStatusDelegate {
                loadingStatusDelegate.dismissLoading()
            } else if let loadingView = controller?.presentedViewController as? LoadingViewController {
                loadingView.dismiss(animated: false)
            }
        }
    }
}

open class MobileSafariViewController: SFSafariViewController, SFSafariViewControllerDelegate {
    var cancelHandler: (() -> Void) = {}

    public init(url: URL, cancelHandler: @escaping (() -> Void)) {
			  super.init(url: url, entersReaderIfAvailable: false)
        self.cancelHandler = cancelHandler
        self.delegate = self;
    }

    public func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        if (!didLoadSuccessfully) {
            controller.dismiss(animated: true, completion: nil)
        }
    }

    public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        self.cancelHandler()
    }
    
}
