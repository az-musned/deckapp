import SwiftUI

/// The minimized form of `FullScreenScreenMirrorView`: a small draggable video preview that
/// floats over the rest of the app while a Mirror/Extend session stays connected in the
/// background. Hosted once at the root of the view hierarchy (see RootView) so it survives tab
/// switches; tapping it re-presents the full-screen view on the same store, and the close
/// button on the bubble stops the session outright without needing to reopen it first.
struct FloatingScreenMirrorBubble: View {
    let store: ScreenMirrorStore
    let onExpand: () -> Void
    let onClose: () -> Void

    private static let size = CGSize(width: 148, height: 92)

    @State private var position: CGPoint?
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let resolvedPosition = position ?? CGPoint(
                x: proxy.size.width - Self.size.width / 2 - DesignToken.Spacing.large,
                y: proxy.size.height - Self.size.height / 2 - DesignToken.Spacing.large - 90
            )

            content
                .frame(width: Self.size.width, height: Self.size.height)
                .position(
                    x: resolvedPosition.x + dragTranslation.width,
                    y: resolvedPosition.y + dragTranslation.height
                )
                .gesture(
                    DragGesture()
                        .updating($dragTranslation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let dragged = CGPoint(x: resolvedPosition.x + value.translation.width, y: resolvedPosition.y + value.translation.height)
                            position = clamped(dragged, in: proxy.size)
                        }
                )
        }
        .allowsHitTesting(true)
    }

    private var content: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onExpand) {
                ZStack {
                    if store.hasReceivedFrame, let videoTrack = store.videoTrack {
                        ScreenMirrorFrameView(videoTrack: videoTrack, contentMode: .scaleAspectFill)
                            .clipped()
                    } else {
                        Color.black
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DesignToken.Radius.control)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private func clamped(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let halfWidth = Self.size.width / 2
        let halfHeight = Self.size.height / 2
        return CGPoint(
            x: min(max(point.x, halfWidth), bounds.width - halfWidth),
            y: min(max(point.y, halfHeight), bounds.height - halfHeight)
        )
    }
}
