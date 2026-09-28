import PhotosUI
import SwiftUI
import UIKit

struct PhotoZoomScrollView: UIViewRepresentable {
    let image: UIImage
    /// Spoken description of the memory this view is showing.
    ///
    /// Set on the `UIView` directly rather than with SwiftUI's
    /// `.accessibilityLabel` on the representable. In the video branch the
    /// enclosing view's label was being applied to a container, which
    /// SwiftUI propagates to every contained element — so the play/pause
    /// button, the 10-second skip and the scrubber all announced the same
    /// date string and could not be told apart. Labelling the media view
    /// itself is what keeps those three intact.
    let accessibilityDescription: String
    /// Mirrors the video branch's `.accessibilityValue`, so VoiceOver can
    /// tell the focused page apart from its neighbours either side.
    let isCurrentMemory: Bool
    /// The moving part, when this is a Live Photo and it has loaded. See
    /// `ZoomingImageScrollView.updateLivePhoto`.
    var livePhoto: PHLivePhoto? = nil
    /// Bumped by the viewer's LIVE button. Only a change is acted on.
    var livePlaybackRequest = 0
    /// False while a sheet or alert is over the viewer.
    var isPlaybackAllowed = true
    let onZoomStateChange: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView()
        scrollView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        scrollView.display(image: image)
        scrollView.applyAccessibility(
            description: accessibilityDescription,
            isCurrentMemory: isCurrentMemory
        )
        scrollView.updateLivePhoto(
            livePhoto,
            playRequest: livePlaybackRequest,
            canPlay: isCurrentMemory && isPlaybackAllowed
        )
        return scrollView
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        uiView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        uiView.display(image: image)
        uiView.applyAccessibility(
            description: accessibilityDescription,
            isCurrentMemory: isCurrentMemory
        )
        uiView.updateLivePhoto(
            livePhoto,
            playRequest: livePlaybackRequest,
            canPlay: isCurrentMemory && isPlaybackAllowed
        )
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate, PHLivePhotoViewDelegate {
    private let imageView = UIImageView()
    /// A Live Photo's motion, inside the image view so it zooms with it.
    ///
    /// Invisible except while playing. The still underneath is the one the
    /// viewer already loaded at full size, so a Live Photo at rest looks
    /// exactly like any other photo, and shows up as fast. Three placements
    /// were weighed: replacing the image view would hold every Live Photo
    /// back until its video had loaded; laying a separate view over the page
    /// would not follow a zoom, so a zoomed photo would jump when it played,
    /// and would take the taps and pinches. Inside the image view it scales
    /// with every zoom for free, and with interaction off it takes no
    /// gestures from anything.
    private let livePhotoView = PHLivePhotoView()
    /// Press and hold plays the Live Photo, as it does in Photos.
    ///
    /// Ours rather than `PHLivePhotoView`'s own recogniser, which would need
    /// the live view to take touches and so sit in the way of the zoom and
    /// the chrome tap.
    private let livePressGesture = UILongPressGestureRecognizer()
    private let singleTapGesture = UITapGestureRecognizer()
    private let singleTapPolicy = WaitForLivePress()
    private var livePhotoIdentifier: ObjectIdentifier?
    private var livePlaybackState = LivePhotoPlayback.State()
    private var canPlayLivePhoto = false
    private var lastNamedLiveAction: Bool?
    private var currentImageIdentifier: ObjectIdentifier?
    private var configuredBoundsSize: CGSize = .zero
    private var onZoomStateChange: ((Bool) -> Void)?
    private var onSingleTap: (() -> Void)?
    /// The last value handed to `onZoomStateChange`, so an unchanged one is
    /// never handed over again. `nil` until the first report.
    private var lastReportedZoomState: Bool?
    /// True only while `display(image:)` drives a synchronous layout, which
    /// happens inside SwiftUI's update pass.
    private var isApplyingImage = false
    /// The state the custom action is currently *named* for, which is not the
    /// same question as the one `lastReportedZoomState` answers.
    private var lastNamedZoomAction: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else {
            return
        }

        // Re-fit whenever the bounds size itself changes (e.g. rotation), not just
        // on first layout — otherwise a stale fit from the old bounds persists.
        if configuredBoundsSize != bounds.size {
            configureForCurrentBounds(using: image)
            configuredBoundsSize = bounds.size
        } else {
            centerImage()
        }
    }

    /// Makes the photo something VoiceOver can find and operate.
    ///
    /// Neither this scroll view nor its `UIImageView` was an accessibility
    /// element, and a `UIImageView` is not one by default, so swiping
    /// through the viewer with VoiceOver announced nothing at all about the
    /// photo on screen. Worse, the single tap that toggles the chrome and
    /// the double tap that zooms are `UITapGestureRecognizer`s on a
    /// non-element view: VoiceOver's own double tap is "activate", which
    /// needs an element with an activate action, so there was no way to
    /// zoom a photo or to bring the chrome back once it was hidden.
    ///
    /// The pager itself was already done properly, with named
    /// `accessibilityAction`s for previous and next memory; zoom and chrome
    /// just never got the same treatment.
    func applyAccessibility(description: String, isCurrentMemory: Bool) {
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = description
        // Photos are the dominant case in a photo-memories app, and only the
        // video branch got this back when the container label was moved.
        accessibilityValue = isCurrentMemory ? "Current memory" : ""
        accessibilityHint = "Double tap to show or hide the controls."
        refreshZoomAction()
    }

    /// Names the zoom action for the state the view is actually in.
    ///
    /// Kept separate from `applyAccessibility` because that only runs from
    /// `makeUIView`/`updateUIView`. Zooming out ran
    /// `setZoomScale(_:animated: true)` and then reported the new state on the
    /// very next line, so the SwiftUI update it triggered re-read `zoomScale`
    /// while the animation was still mid-flight and rebuilt the action as
    /// "Zoom out". The settling frames then reported the same value the
    /// de-dup guard had already recorded, so nothing ran again — leaving a
    /// fully zoomed-out photo whose only action was called "Zoom out" and
    /// which zoomed *in* when activated.
    ///
    /// Called from `scrollViewDidZoom`, so it tracks the animation rather
    /// than a snapshot taken before it.
    private func refreshZoomAction() {
        let zoomedIn = isZoomedIn
        let hasLivePhoto = livePhotoView.livePhoto != nil
        guard lastNamedZoomAction != zoomedIn
            || lastNamedLiveAction != hasLivePhoto
            || accessibilityCustomActions?.isEmpty != false else { return }
        lastNamedZoomAction = zoomedIn
        lastNamedLiveAction = hasLivePhoto
        var actions = [
            UIAccessibilityCustomAction(
                name: zoomedIn ? "Zoom out" : "Zoom in",
                target: self,
                selector: #selector(accessibilityToggleZoom)
            )
        ]
        // Press and hold is not a gesture VoiceOver can make.
        if hasLivePhoto {
            actions.append(UIAccessibilityCustomAction(
                name: "Play Live Photo",
                target: self,
                selector: #selector(accessibilityPlayLivePhoto)
            ))
        }
        accessibilityCustomActions = actions
    }

    @objc private func accessibilityPlayLivePhoto() -> Bool {
        guard canPlayLivePhoto, livePhotoView.livePhoto != nil else { return false }
        livePhotoView.startPlayback(with: .full)
        return true
    }

    /// VoiceOver's activate gesture maps onto the single tap, which is the
    /// chrome toggle — the same thing a sighted user's tap does.
    override func accessibilityActivate() -> Bool {
        onSingleTap?()
        return true
    }

    @objc private func accessibilityToggleZoom() -> Bool {
        if isZoomedIn {
            setZoomScale(minimumZoomScale, animated: true)
            reportZoomState(false)
        } else {
            let target = min(maximumZoomScale, 2.5)
            zoom(to: zoomRect(for: target, centeredAt: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)), animated: true)
        }
        return true
    }

    private var isZoomedIn: Bool {
        zoomScale > minimumZoomScale + 0.01
    }

    func updateCallbacks(
        onZoomStateChange: @escaping (Bool) -> Void,
        onSingleTap: @escaping () -> Void
    ) {
        self.onZoomStateChange = onZoomStateChange
        self.onSingleTap = onSingleTap
    }

    func display(image: UIImage) {
        let identifier = ObjectIdentifier(image)
        guard currentImageIdentifier != identifier else { return }

        currentImageIdentifier = identifier
        imageView.image = image
        configuredBoundsSize = .zero
        // `layoutIfNeeded` runs `layoutSubviews` *synchronously*, and
        // `configuredBoundsSize = .zero` above guarantees it takes the
        // re-fit branch, which reports a zoom state. This method is reached
        // from `updateUIView`, so without the flag that report writes the
        // presenting view's `@State` from inside SwiftUI's update pass.
        isApplyingImage = true
        setNeedsLayout()
        layoutIfNeeded()
        isApplyingImage = false
    }

    /// Reports a zoom state only when it actually changed.
    ///
    /// `scrollViewDidZoom` fires once per display frame while a pinch is in
    /// progress and while the zoom bounce settles, and it used to call
    /// straight out on every one of them. The value it writes is a `@State`
    /// on the presenting view, so a pinch invalidated and re-evaluated the
    /// whole full-screen body — the `GeometryReader`, the three-page
    /// `ForEach` and all the chrome — sixty to a hundred and twenty times a
    /// second, to hand it the same boolean it already held. The pager's drag
    /// path had this fixed by windowing the `ForEach`; the pinch path kept it.
    private func reportZoomState(_ isZoomed: Bool) {
        // Deliberately before the early-out below, so this tracks reality even
        // when the reported boolean has not changed.
        //
        // At minimum zoom the content is exactly the size of the scroll view,
        // so there is nothing to pan — but the pan recogniser was still live,
        // and `bounces` let it rubber-band the photo under the finger. The
        // pager's own drag needs 15 points before it activates, so every
        // photo-to-photo swipe began with the image sliding a little and then
        // snapping back as the pager took over. Measured against a screen
        // recording, that snap was a single frame worth up to a third of the
        // screen width, and it is the whole reason swiping between two photos
        // felt worse than swiping from a video, which has no scroll view.
        //
        // The recogniser is disabled rather than `isScrollEnabled` set false:
        // that property also stops the scroll view accepting touches, which
        // would take the single-tap chrome toggle, the double-tap zoom and
        // pinch-to-zoom with it. This turns off panning and nothing else.
        panGestureRecognizer.isEnabled = isZoomed

        guard lastReportedZoomState != isZoomed else { return }
        lastReportedZoomState = isZoomed
        guard let onZoomStateChange else { return }

        guard isApplyingImage else {
            onZoomStateChange(isZoomed)
            return
        }
        // Reached from inside a SwiftUI update pass — see `display(image:)`.
        // One hop puts the state write after that pass instead of during it.
        DispatchQueue.main.async { onZoomStateChange(isZoomed) }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        refreshZoomAction()
        reportZoomState(isZoomedIn)
    }

    private func configure() {
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        delaysContentTouches = false
        canCancelContentTouches = true
        // Starts unzoomed, so panning starts off. `reportZoomState` owns it
        // from here.
        panGestureRecognizer.isEnabled = false
        maximumZoomScale = 4
        minimumZoomScale = 1
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.isUserInteractionEnabled = false
        livePhotoView.playbackGestureRecognizer.isEnabled = false
        livePhotoView.alpha = 0
        livePhotoView.delegate = self
        imageView.addSubview(livePhotoView)

        let singleTap = singleTapGesture
        singleTap.addTarget(self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTapPolicy.livePress = livePressGesture
        singleTap.delegate = singleTapPolicy

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)

        livePressGesture.addTarget(self, action: #selector(handleLivePress(_:)))
        livePressGesture.minimumPressDuration = 0.25
        livePressGesture.isEnabled = false
        addGestureRecognizer(livePressGesture)
    }

    // MARK: - Live Photo

    /// Hands this page its Live Photo, if it has one, and plays it when
    /// asked.
    ///
    /// Called on every SwiftUI update, so everything here only acts on a
    /// change: a different Live Photo, or a new press of the LIVE button.
    /// Nothing plays on arrival; see `LivePhotoPlayback`.
    func updateLivePhoto(_ livePhoto: PHLivePhoto?, playRequest: Int, canPlay: Bool) {
        canPlayLivePhoto = canPlay

        let identifier = livePhoto.map(ObjectIdentifier.init)
        let arrived = identifier != nil && identifier != livePhotoIdentifier
        if identifier != livePhotoIdentifier {
            livePhotoIdentifier = identifier
            livePhotoView.stopPlayback()
            livePhotoView.alpha = 0
            livePhotoView.livePhoto = livePhoto
            livePressGesture.isEnabled = livePhoto != nil
            refreshZoomAction()
        }

        switch LivePhotoPlayback.update(
            &livePlaybackState,
            request: playRequest,
            motionArrived: arrived,
            hasMotion: livePhoto != nil,
            canPlay: canPlay
        ) {
        case .nothing:
            break
        case .stop:
            livePhotoView.stopPlayback()
        case .full:
            livePhotoView.startPlayback(with: .full)
        }
    }

    @objc private func handleLivePress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard canPlayLivePhoto, livePhotoView.livePhoto != nil else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            livePhotoView.startPlayback(with: .full)
        case .ended, .cancelled, .failed:
            // Letting go stops it, as in Photos.
            livePhotoView.stopPlayback()
        default:
            break
        }
    }

    /// Shown only while moving, so at rest the full-size still is what is
    /// on screen.
    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        livePhotoView.alpha = 1
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        livePhotoView.alpha = 0
    }


    private func configureForCurrentBounds(using image: UIImage) {
        // Reset zoom before assigning frame: Apple states frame is undefined when
        // the view's transform is not identity (i.e. when zoomScale != 1).
        zoomScale = 1
        minimumZoomScale = 1
        maximumZoomScale = 4
        let fittedSize = aspectFitSize(for: image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        // Set here rather than by autoresizing, which scales from the image
        // view's first, zero size. A zoom transforms the image view without
        // changing its bounds, so this holds at every zoom.
        livePhotoView.frame = imageView.bounds
        contentSize = fittedSize
        contentOffset = .zero
        centerImage()
        reportZoomState(false)
    }

    private func aspectFitSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return containerSize
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            return CGSize(
                width: containerSize.width,
                height: containerSize.width / imageAspect
            )
        } else {
            return CGSize(
                width: containerSize.height * imageAspect,
                height: containerSize.height
            )
        }
    }

    // Anchors the image view's frame within the scroll view's bounds directly
    // instead of relying on `contentInset`. `contentInset` only changes the
    // scrollable range — it does not move `contentOffset` — so an image whose
    // fitted size is smaller than the bounds in one dimension (any photo whose
    // aspect ratio doesn't match the screen, which is common for older photos
    // resurfaced by this "on this day" app) was rendering pinned to the
    // top-left with blank space left uncovered below/right of it.
    private func centerImage() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame

        if frameToCenter.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }

        if frameToCenter.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }

        imageView.frame = frameToCenter
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomedIn {
            setZoomScale(minimumZoomScale, animated: true)
            reportZoomState(false)
            return
        }

        let targetZoomScale = min(maximumZoomScale, 2.5)
        let tapPoint = gesture.location(in: imageView)
        zoom(to: zoomRect(for: targetZoomScale, centeredAt: tapPoint), animated: true)
    }

    private func zoomRect(for scale: CGFloat, centeredAt point: CGPoint) -> CGRect {
        let width = bounds.size.width / scale
        let height = bounds.size.height / scale

        return CGRect(
            x: point.x - (width / 2),
            y: point.y - (height / 2),
            width: width,
            height: height
        )
    }
}

/// Makes the chrome tap wait for a press-and-hold to fail, but only on a Live
/// Photo.
///
/// Without it, letting go after holding a Live Photo also counted as a tap
/// and hid the controls. Asked on every touch rather than set once with
/// `require(toFail:)`, so an ordinary photo, where the press is switched off,
/// never waits on it.
///
/// Its own object rather than the scroll view: a `UIScrollView` is already
/// the delegate of its own pan and pinch recognisers, and answering this for
/// them from the subclass would be answering for UIKit.
private final class WaitForLivePress: NSObject, UIGestureRecognizerDelegate {
    weak var livePress: UILongPressGestureRecognizer?

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let livePress else { return false }
        return otherGestureRecognizer === livePress && livePress.isEnabled
    }
}
