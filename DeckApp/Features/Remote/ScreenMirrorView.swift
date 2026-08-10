import AVFoundation
import SwiftUI
import UIKit

struct FullScreenScreenMirrorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ScreenMirrorStore

    var body: some View {
        GeometryReader { proxy in
            // The iPhone interface is locked to portrait (see Info.plist) specifically so
            // rotating the device never changes RootView's width-driven layout -- which was
            // tearing down this very view's presentation. The desktop/virtual-monitor content
            // is landscape-shaped regardless, so when the available space is portrait-shaped
            // (always true on a locked iPhone, never true on an iPad, which still rotates
            // natively), rotate the whole stream canvas 90° instead: the user turns their
            // phone sideways to view it, the interface orientation itself never moves.
            let isPortraitSpace = proxy.size.width < proxy.size.height
            streamContent
                .frame(
                    width: isPortraitSpace ? proxy.size.height : proxy.size.width,
                    height: isPortraitSpace ? proxy.size.width : proxy.size.height
                )
                .rotationEffect(.degrees(isPortraitSpace ? 90 : 0))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await store.startMirroring()
        }
        .onDisappear {
            Task { await store.stopMirroring() }
        }
    }

    private var streamContent: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            if store.hasReceivedFrame {
                ScreenMirrorFrameView(displayLayer: store.displayLayer, videoGravity: .resizeAspect)
            } else {
                statusOverlay
            }

            if store.hasReceivedFrame, store.isStale || store.connectionState != .connected {
                staleBanner
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .glassSurface(.elevated, cornerRadius: 999)
            .padding()
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: DesignToken.Spacing.small) {
            ProgressView()
            Text(store.connectionState.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var staleBanner: some View {
        VStack {
            Spacer()
            Text(store.connectionState == .connected ? "Reconnecting…" : store.connectionState.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, DesignToken.Spacing.medium)
                .padding(.vertical, DesignToken.Spacing.small)
                .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control)
                .padding(.bottom, DesignToken.Spacing.large)
        }
    }
}

/// Hosts `ScreenMirrorStore.displayLayer` (the same instance the store enqueues decoded
/// frames onto) as a sublayer, keeping its frame in sync via `layoutSubviews`. Frames are
/// enqueued on the store's layer instance directly -- creating a fresh layer here (e.g. via
/// a `layerClass` override) would enqueue onto a layer nothing ever displays.
private final class ScreenMirrorHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        // This view has nothing of its own to handle touches for -- it's a passive video
        // surface. Left enabled (the UIView default), it swallows every touch in its bounds,
        // including the SwiftUI close button layered on top of it in the ZStack.
        isUserInteractionEnabled = false
        displayLayer.removeFromSuperlayer()
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}

private struct ScreenMirrorFrameView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> ScreenMirrorHostView {
        ScreenMirrorHostView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: ScreenMirrorHostView, context: Context) {
        displayLayer.videoGravity = videoGravity
    }
}
