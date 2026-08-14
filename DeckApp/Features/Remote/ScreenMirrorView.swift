import SwiftUI
import UIKit
@preconcurrency import WebRTC

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
            ZStack(alignment: .topLeading) {
                Color.black

                streamContent
                    .frame(
                        width: isPortraitSpace ? proxy.size.height : proxy.size.width,
                        height: isPortraitSpace ? proxy.size.width : proxy.size.height
                    )
                    .rotationEffect(.degrees(isPortraitSpace ? 90 : 0))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Deliberately kept OUTSIDE the rotated `streamContent`: `.rotationEffect`
                // rotates hit-testing along with the visuals, so when this button lived
                // inside streamContent its tap target rotated 90° away from where it's
                // actually drawn on a locked-portrait iPhone -- taps at the visible X almost
                // never landed on it. Real screen-space overlay controls (close button,
                // stats overlay) belong here, not inside the rotated content.
                closeButton

                if let statsText = store.statsText {
                    statsOverlay(statsText)
                }
            }
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

            if store.hasReceivedFrame, let videoTrack = store.videoTrack {
                // .scaleToFill stretches to exactly fill the view regardless of the source's
                // actual aspect ratio -- fine when phone and source dimensions happen to
                // match, but the virtual display extend mode attaches doesn't necessarily
                // match the phone's screen aspect ratio, so it was visibly distorting the
                // image. .scaleAspectFit preserves the real aspect ratio (letterboxed) for
                // both modes instead.
                ScreenMirrorFrameView(videoTrack: videoTrack, contentMode: .scaleAspectFit)
            } else {
                statusOverlay
            }

            if store.hasReceivedFrame, store.isStale || store.connectionState != .connected {
                staleBanner
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .glassSurface(.elevated, cornerRadius: 999)
        .padding()
    }

    // TEMPORARY: diagnosing the "connects but renders ~1fps" report -- see
    // ScreenMirrorPeerConnection.swift's startStatsPolling. Remove alongside that once resolved.
    private func statsOverlay(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, DesignToken.Spacing.small)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 4)
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
        // Passive video surface -- it has nothing of its own to handle touches for, and left
        // enabled (the UIView default) it can swallow taps meant for controls layered on top.
        view.isUserInteractionEnabled = false
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
