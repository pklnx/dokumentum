import UIKit

/// Placeholder for the share extension: it completes the request at once and takes nothing over.
/// Step 3 hands the files to the app through the app-group queue. The extension never opens the store
/// and links neither package (plan.md, section 3.4).
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extensionContext?.completeRequest(returningItems: nil)
    }
}
