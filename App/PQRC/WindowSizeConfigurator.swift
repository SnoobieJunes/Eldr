// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

#if targetEnvironment(macCatalyst)
    import UIKit

    /// Mac Catalyst ONLY: makes the app window freely resizable above a sane
    /// minimum by setting AppKit-level `UIWindowScene.sizeRestrictions`.
    ///
    /// SwiftUI's `.windowResizability` / `.frame(minWidth:…)` are unreliable on Mac
    /// Catalyst — the window can refuse to resize at runtime despite them. The lever
    /// that actually sticks is `UIWindowScene.sizeRestrictions`, which is UIKit-only.
    /// So we bridge to it with a zero-size `UIViewRepresentable` attached as a
    /// background: in `updateUIView` we walk up to the hosting `UIWindowScene` and
    /// set its min/max. We defer to a later main-actor turn because the view's
    /// `window` (and thus its `windowScene`) isn't wired up yet during the first
    /// `updateUIView` of a freshly created scene. `updateUIView` is already
    /// `@MainActor`, so a `Task { @MainActor in … }` re-enters the main actor on
    /// the next turn (the codebase's established defer pattern; it also keeps Swift
    /// 6 strict-concurrency happy capturing the non-`Sendable` `UIView`).
    ///
    /// minimumSize = 480×600 (can't be squeezed below a usable size);
    /// maximumSize = .greatestFiniteMagnitude on both axes (no upper bound — the
    /// user can drag it as large as they like).
    struct WindowSizeConfigurator: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            UIView(frame: .zero)
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            Task { @MainActor in
                guard let scene = uiView.window?.windowScene,
                    let restrictions = scene.sizeRestrictions
                else { return }
                restrictions.minimumSize = CGSize(width: 480, height: 600)
                restrictions.maximumSize = CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    /// Catalyst build: attach the real configurator as an (invisible) background.
    struct WindowSizeConfiguratorModifier: ViewModifier {
        func body(content: Content) -> some View {
            content.background(WindowSizeConfigurator())
        }
    }
#else
    /// iPhone / iPad / "Designed for iPad" build: a no-op. `sizeRestrictions` is a
    /// desktop-window concept that doesn't exist here, so the whole mechanism
    /// compiles out — iPhone/iPad layout is completely unaffected.
    struct WindowSizeConfiguratorModifier: ViewModifier {
        func body(content: Content) -> some View { content }
    }
#endif
