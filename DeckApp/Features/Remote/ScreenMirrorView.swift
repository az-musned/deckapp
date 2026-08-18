import SwiftUI
import UIKit
@preconcurrency import WebRTC

struct FullScreenScreenMirrorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ScreenMirrorStore
    let remote: RemoteInputController
    @State private var isDragging = false
    @State private var videoSize = CGSize.zero
    // Set right before dismiss() when the user taps minimize (not close), so onDisappear below
    // knows to leave the connection running for the floating bubble rather than tearing it down.
    @State private var isMinimizing = false
    // Both touch surfaces below are full-screen UIViewRepresentables handling their own raw
    // UIKit touch/gesture dispatch, and relying on them to correctly defer to a SwiftUI Button
    // layered on top (via a hit-test delegate/override checking the button's measured frame)
    // turned out to be fragile in practice -- whether that actually works depends on exactly
    // how SwiftUI happens to compose UIViewRepresentable content into the real UIKit view
    // hierarchy, which isn't documented or guaranteed. The robust fix is to make the two views
    // never physically overlap in the first place: reserve a fixed strip across the top of the
    // screen -- comfortably larger than the close button's rendered footprint -- that the touch
    // surfaces are simply never given as part of their own frame. With no overlap, there's no
    // hit-testing ambiguity left to get wrong.
    private static let closeButtonReservedHeight: CGFloat = 100

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
                // rotates hit-testing along with the visuals, so anything interactive placed
                // inside streamContent has its tap/gesture coordinates rotated 90° away from
                // where it's actually drawn on a locked-portrait iPhone -- the close button's
                // tap target almost never landed on it, and the touchpad's relative-delta
                // gestures would report the wrong axis (drag right -> reported as drag down)
                // for the same reason. Real screen-space overlay controls (close button, stats
                // overlay, the touchpad) belong here, not inside the rotated content. The
                // touchpad is added before closeButton/statsOverlay so it sits underneath them
                // in the ZStack and doesn't swallow their taps.
                if store.hasReceivedFrame, store.videoTrack != nil {
                    if store.mode == .extend {
                        // Extend mode is a real second monitor, so touch acts like a
                        // touchscreen -- tap/drag position maps 1:1 onto the virtual
                        // display, unlike mirror mode's relative trackpad below. Inset from
                        // the top to physically clear the close button (see
                        // closeButtonReservedHeight); the touch point this surface reports is
                        // in its own (inset) local space, so the reserved height is added back
                        // before feeding it to absoluteTouchFraction, which expects points in
                        // the outer, un-inset proxy space.
                        RemoteAbsoluteTouchSurface { point, phase in
                            let outerPoint = CGPoint(x: point.x, y: point.y + Self.closeButtonReservedHeight)
                            guard let fraction = Self.absoluteTouchFraction(
                                for: outerPoint,
                                proxySize: proxy.size,
                                isPortraitSpace: isPortraitSpace,
                                videoSize: videoSize
                            ) else { return }
                            remote.sendAbsoluteTouch(xFraction: fraction.x, yFraction: fraction.y, phase: phase)
                        }
                        .padding(.top, Self.closeButtonReservedHeight)
                    } else {
                        // Touch-as-trackpad control over the PC while watching -- same
                        // relative-delta gesture surface used in the dedicated Remote tab
                        // (RemoteControlView.swift), reused here rather than rebuilt. Also
                        // inset from the top; harmless here since this surface only ever
                        // reports relative deltas, which an inset doesn't change.
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
                        .padding(.top, Self.closeButtonReservedHeight)
                    }
                }

                closeButton

                if isDragging {
                    draggingBanner
                }

                if let statsText = store.statsText {
                    statsOverlay(statsText)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            // Resuming a session that's already running in the background because it was
            // minimized -- it already holds a consumer token from before, so don't acquire a
            // second one (that would leave the token count one too high forever, since a
            // matching stopMirroring() will only ever be called once on the way back out).
            if remote.minimizedMirror === store {
                remote.minimizedMirror = nil
            } else {
                await store.startMirroring()
            }
        }
        .onDisappear {
            guard !isMinimizing else { return }
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
                // image. .scaleAspectFit preserves the real aspect ratio (letterboxed) for both
                // modes instead. Paired with a Windows Agent change that sets the virtual
                // display to 1920x1080 on attach (VirtualDisplayAttachment.cs) instead of the
                // driver's 800x600 default, which keeps the remaining letterboxing small on
                // most iPads.
                ScreenMirrorFrameView(videoTrack: videoTrack, contentMode: .scaleAspectFit, onSizeChange: { videoSize = $0 })
            } else {
                statusOverlay
            }

            if store.hasReceivedFrame, store.isStale || store.connectionState != .connected {
                staleBanner
            }
        }
    }

    private var closeButton: some View {
        HStack(spacing: DesignToken.Spacing.small) {
            Button {
                // Order matters: set both before dismiss() fires SwiftUI's teardown, since
                // onDisappear reads isMinimizing synchronously once the dismissal completes.
                remote.minimizedMirror = store
                isMinimizing = true
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .glassSurface(.elevated, cornerRadius: 999)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .glassSurface(.elevated, cornerRadius: 999)
        }
        .padding()
    }

    private var draggingBanner: some View {
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

    /// Maps a touch point in the overlay's outer (unrotated, full-screen) coordinate space to
    /// a normalized (0-1) fraction of the letterboxed video content, or nil if outside it or
    /// the video size isn't known yet. The touch surface sits *outside* `streamContent`'s own
    /// rotation transform (see the comment above the ZStack), so on a portrait-locked iPhone
    /// (`isPortraitSpace`) this first has to invert that 90°-clockwise rotation by hand:
    /// streamContent's own pre-rotation frame is (height, width) swapped from the outer proxy
    /// size, and a point's outer position after a +90° rotation about the shared center works
    /// out to outerX = proxyWidth - localY, outerY = localX -- inverted here as
    /// localX = outerY, localY = proxyWidth - outerX. On iPad (never portrait-locked,
    /// `isPortraitSpace` is false) streamContent isn't rotated and exactly overlays the proxy
    /// rect, so outer and local coordinates are identical.
    private static func absoluteTouchFraction(
        for point: CGPoint,
        proxySize: CGSize,
        isPortraitSpace: Bool,
        videoSize: CGSize
    ) -> (x: Double, y: Double)? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }

        let localSize = isPortraitSpace
            ? CGSize(width: proxySize.height, height: proxySize.width)
            : proxySize
        let localPoint = isPortraitSpace
            ? CGPoint(x: point.y, y: proxySize.width - point.x)
            : point

        let containerAspect = localSize.width / localSize.height
        let videoAspect = videoSize.width / videoSize.height
        let contentRect: CGRect
        if videoAspect > containerAspect {
            let contentWidth = localSize.width
            let contentHeight = contentWidth / videoAspect
            contentRect = CGRect(x: 0, y: (localSize.height - contentHeight) / 2, width: contentWidth, height: contentHeight)
        } else {
            let contentHeight = localSize.height
            let contentWidth = contentHeight * videoAspect
            contentRect = CGRect(x: (localSize.width - contentWidth) / 2, y: 0, width: contentWidth, height: contentHeight)
        }
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }

        let fractionX = (localPoint.x - contentRect.minX) / contentRect.width
        let fractionY = (localPoint.y - contentRect.minY) / contentRect.height
        return (Double(min(max(fractionX, 0), 1)), Double(min(max(fractionY, 0), 1)))
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
struct ScreenMirrorFrameView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack
    let contentMode: UIView.ContentMode
    var onSizeChange: ((CGSize) -> Void)? = nil

    final class Coordinator {
        var attachedTrack: RTCVideoTrack?
        var sizeObserver: VideoSizeObserver?
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
        attachSizeObserver(to: videoTrack, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = contentMode
        guard context.coordinator.attachedTrack !== videoTrack else { return }
        Self.detachSizeObserver(from: context.coordinator.attachedTrack, coordinator: context.coordinator)
        context.coordinator.attachedTrack?.remove(uiView)
        videoTrack.add(uiView)
        context.coordinator.attachedTrack = videoTrack
        attachSizeObserver(to: videoTrack, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        detachSizeObserver(from: coordinator.attachedTrack, coordinator: coordinator)
        coordinator.attachedTrack?.remove(uiView)
    }

    private func attachSizeObserver(to track: RTCVideoTrack, coordinator: Coordinator) {
        guard let onSizeChange else { return }
        let observer = VideoSizeObserver()
        observer.onSizeChange = onSizeChange
        track.add(observer)
        coordinator.sizeObserver = observer
    }

    private static func detachSizeObserver(from track: RTCVideoTrack?, coordinator: Coordinator) {
        guard let observer = coordinator.sizeObserver else { return }
        track?.remove(observer)
        coordinator.sizeObserver = nil
    }
}

/// A second, frame-ignoring renderer added to the same track alongside `RTCMTLVideoView`
/// purely to learn the video's actual pixel dimensions (`setSize`) -- needed so extend mode's
/// touch surface can compute the real letterboxed content rect instead of assuming the video
/// fills its container. Multiple `RTCVideoRenderer`s can observe one track simultaneously.
// nonisolated: WebRTC invokes RTCVideoRenderer methods from its own internal capture/render
// thread, not the main actor. Under this project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
// leaving this class main-actor-isolated by default makes the Swift runtime trap
// (_checkExpectedExecutor / dispatch_assert_queue_fail) the moment WebRTC calls setSize(_:)
// off-main -- observed as an EXC_BREAKPOINT crash as soon as extend mode starts receiving
// frames. `onSizeChange` is assigned once right after construction, before the observer is
// handed to WebRTC, and never mutated afterward, so reading it from an arbitrary thread here
// is safe despite not being statically provable to the compiler.
final class VideoSizeObserver: NSObject, RTCVideoRenderer, @unchecked Sendable {
    nonisolated(unsafe) var onSizeChange: ((CGSize) -> Void)?

    nonisolated func setSize(_ size: CGSize) {
        let callback = onSizeChange
        DispatchQueue.main.async { callback?(size) }
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {}
}
