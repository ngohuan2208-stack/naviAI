import UIKit
import WebKit

/// Plain UIView that hosts every tab's WKWebView as subviews. Only the active
/// tab is visible/hit-testable; the others stay alive so their state, cookies
/// and JS are preserved while switching back and forth.
final class WebSurfaceView: UIView {
    weak var store: BrowserStore?

    override func layoutSubviews() {
        super.layoutSubviews()
        if store?.viewportSize != bounds.size {
            store?.surfaceDidLayout(size: bounds.size)
        }
        for sub in subviews {
            sub.frame = bounds
        }
    }

    /// Bring the subview graph in sync with the store's tabs.
    func reconcile(tabs: [TabItem], activeID: UUID?) {
        let owned = Set(tabs.map { ObjectIdentifier($0.coordinator.webView) })
        for sub in subviews {
            guard let wv = sub as? WKWebView else { continue }
            if !owned.contains(ObjectIdentifier(wv)) {
                wv.removeFromSuperview()
            }
        }
        for tab in tabs {
            let wv = tab.coordinator.webView
            if wv.superview !== self {
                wv.frame = bounds
                addSubview(wv)
            }
            let isActive = tab.id == activeID
            wv.isHidden = !isActive
            wv.isUserInteractionEnabled = isActive
        }
        if let activeID, let tab = tabs.first(where: { $0.id == activeID }) {
            bringSubviewToFront(tab.coordinator.webView)
        }
    }
}
