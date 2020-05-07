///
/// Copyright (c) 2020 Dropbox, Inc. All rights reserved.
///

import Foundation
import UIKit

/// A VC with a loading spinner at its view center.
class LoadingViewController: UIViewController {
    private let loadingSpinner: UIActivityIndicatorView

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        loadingSpinner = UIActivityIndicatorView(style: .whiteLarge)
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable, message: "init(coder:) has not been implemented")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        loadingSpinner.removeFromSuperview()
        view.addSubview(loadingSpinner)
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        loadingSpinner.startAnimating()
    }
}
