import SwiftUI
import UIKit
@preconcurrency import WebRTC

struct FullScreenScreenMirrorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ScreenMirrorStore
    let remote: RemoteInputController
    @State private var isDragging = false

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

            if store.hasReceivedFrame, let videoTrack = store.videoTrack {
                // Extend used to force .scaleToFill, stretching the video to fill the frame
                // whenever the virtual monitor's resolution didn't match the device's aspect
                // ratio -- visibly distorted. .scaleAspectFit never distorts; the Windows Agent
                // now also sets the virtual monitor to 1920x1080 on attach
                // (VirtualDisplayAttachment.cs), which keeps the remaining letterboxing small
                // on most iPads without needing the client to negotiate an exact match.
                ScreenMirrorFrameView(videoTrack: videoTrack, contentMode: .scaleAspectFit)

                // Touch-as-trackpad control over the PC while watching -- same relative-delta
                // gesture surface used in the dedicated Remote tab (RemoteControlView.swift),
                // reused here rather than rebuilt. Sits below the dismiss button/banners in the
                // ZStack so they still receive their own taps.
                RemoteTouchpadSurface(
                    pointerMoved: { dx, dy in remote.enqueuePointer(deltaX: dx, deltaY: dy) },
                    scrolled: { dx, dy in remote.enqueueScroll(deltaX: dx, deltaY: dy) },
                    tapped: { remote.click(.left) },
                    twoFingerTapped: {
                        guard remote.preferences.twoFingerRightClick else { return }
                        remote.click(.right)
                    },
                    dragChanged: { active in
                        isDragging = active
                        remote.setDrag(active: active)
                    }
                )
            } else {
                statusOverlay
            }

            if store.hasReceivedFrame, store.isStale || store.connectionState != .connected {
                staleBanner
            }

            if isDragging {
                VStack {
                    Spacer()
                    Text("Dragging")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, DesignToken.Spacing.medium)
                        .padding(.vertical, DesignToken.Spacing.small)
                        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.control)
                        .padding(.bottom, DesignToken.Spacing.large)
                }
                .allowsHitTesting(false)
            }

            // TEMPORARY: diagnosing the "connects but renders ~1fps" report -- see
            // ScreenMirrorPeerConnection.swift's startStatsPolling. Remove this overlay
            // alongside that once resolved.
            if let statsText = store.statsText {
                VStack {
                    Spacer()
                    Text(statsText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignToken.Spacing.small)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 4)
                }
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
