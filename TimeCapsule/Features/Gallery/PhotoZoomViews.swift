import SwiftUI
import UIKit

struct PhotoZoomScrollView: UIViewRepresentable {
    let image: UIImage
    let onZoomStateChange: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView()
        scrollView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        scrollView.display(image: image)
        return scrollView
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        uiView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        uiView.display(image: image)
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
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
        reportZoomState(zoomScale > minimumZoomScale + 0.01)
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
        maximumZoomScale = 4
        minimumZoomScale = 1
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }

    private func configureForCurrentBounds(using image: UIImage) {
        // Reset zoom before assigning frame: Apple states frame is undefined when
        // the view's transform is not identity (i.e. when zoomScale != 1).
        zoomScale = 1
        minimumZoomScale = 1
        maximumZoomScale = 4
        let fittedSize = aspectFitSize(for: image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
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
        if zoomScale > minimumZoomScale + 0.01 {
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
