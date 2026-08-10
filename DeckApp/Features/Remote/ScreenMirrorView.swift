import AVFoundation
import SwiftUI
import UIKit

struct FullScreenScreenMirrorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ScreenMirrorStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if store.hasReceivedFrame {
                ScreenMirrorFrameView(displayLayer: store.displayLayer, videoGravity: store.mode == .extend ? .resize : .resizeAspect)
                    .ignoresSafeArea()
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
        .task {
            await store.startMirroring()
        }
        .onDisappear {
            Task { await store.stopMirroring() }
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
