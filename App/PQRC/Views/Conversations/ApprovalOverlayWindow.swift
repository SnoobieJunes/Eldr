// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UIKit

/// C4: hosts the ACP approval card in its OWN passthrough UIWindow at `.alert`
/// level, so a pending approval renders ABOVE any sheet or cover. As a
/// `MainView` overlay it sat UNDER presented sheets (Settings, the AI hub, a
/// thread sheet…) — exactly where the user often was when a request arrived —
/// and the node's C-1 timeout then denied it silently. Only the card itself is
/// hittable; everywhere else touches pass through to whatever is beneath.
///
/// Owned by `MainView` (`present` on appear, `dismiss` on disappear) so the
/// window — and its reference to the model — is torn down when the silo locks.
@MainActor
final class ApprovalWindowPresenter {
    private var window: PassthroughWindow?

    func present(model: AppModel) {
        let root = ApprovalOverlayRoot(model: model)
        if let window {
            // Re-presented (e.g. the demo persona switcher swapped models):
            // rebind the root instead of stacking a second window.
            (window.rootViewController as? UIHostingController<ApprovalOverlayRoot>)?
                .rootView = root
            return
        }
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        let overlay = PassthroughWindow(windowScene: scene)
        overlay.rootViewController = host
        overlay.windowLevel = .alert
        overlay.isHidden = false
        window = overlay
    }

    func dismiss() {
        window?.isHidden = true
        window = nil
    }
}

/// Touches on the empty host view fall through to the app window; only the
/// card's own controls take them.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

/// Bottom-anchored card, reading-width-capped so it doesn't sprawl on iPad/Mac.
private struct ApprovalOverlayRoot: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack {
            Spacer()
            ACPApprovalCard(model: model)
                .animation(.spring(duration: 0.3), value: model.acpPermissions.pending.count)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}
