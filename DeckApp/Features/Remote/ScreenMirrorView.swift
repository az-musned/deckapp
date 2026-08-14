import SwiftUI
import UIKit
@preconcurrency import WebRTC

struct FullScreenScreenMirrorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ScreenMirrorStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if store.hasReceivedFrame, let videoTrack = store.videoTrack {
                ScreenMirrorFrameView(videoTrack: videoTrack, contentMode: store.mode == .extend ? .scaleToFill : .scaleAspectFit)
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

/// Hosts an `RTCMTLVideoView` bound to the negotiated remote video track -- WebRTC's own
/// Metal-backed renderer, replacing the old `AVSampleBufferDisplayLayer` sublayer host now
/// that decoding and jitter buffering happen inside the WebRTC stack rather than via
/// per-frame `CMSampleBuffer`s the app assembled itself. A `Coordinator` tracks which track
/// is currently attached so `updateUIView`/`dismantleUIView` can detach cleanly if the track
/// changes or the view goes away (`videoTrack.add`/`.remove` isn't reference-counted).
private struct ScreenMirrorFrameView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack
    let contentMode: UIView.ContentMode

    final class Coordinator {
        var attachedTrack: RTCVideoTrack?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = contentMode
        videoTrack.add(view)
        context.coordinator.attachedTrack = videoTrack
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = contentMode
        guard context.coordinator.attachedTrack !== videoTrack else { return }
        context.coordinator.attachedTrack?.remove(uiView)
        videoTrack.add(uiView)
        context.coordinator.attachedTrack = videoTrack
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(uiView)
    }
}
