import SwiftUI
import Photos
import UIKit
import CoreLocation
import LinkPresentation
import MapKit
import UniformTypeIdentifiers

struct FullScreenPhotoView: View {
    let asset: PHAsset
    let allAssets: [PHAsset]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var currentIndex: Int
    @State private var showChrome = true
    @State private var visibleAssets: [PHAsset]
    @State private var showDeleteConfirm = false
    @State private var deleteError: String? = nil
    @State private var shareItem: ShareItem? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var isCurrentAssetZoomed = false
    @State private var isVideoScrubbing = false
    /// The translation already accumulated when the drag gesture activated.
    ///
    /// `DragGesture(minimumDistance: 15)` does not report anything until the
    /// finger has travelled 15 points, and then reports the *whole*
    /// translation including those 15 — so the photo jumped sideways the
    /// instant a swipe registered. Subtracting this makes the page start
    /// moving from exactly where the finger already is, which is most of what
    /// "snappy versus smooth" actually was.
    @State private var dragActivationSlop: CGFloat?
    @State private var locationName: String? = nil
    // Captures the asset at the moment info is opened, rather than reading
    // `visibleAssets[currentIndex]` live while the sheet is up. "Feature Less
    // Often" lives inside this sheet and can shrink `visibleAssets` — down to
    // empty, if it was the last one — while the sheet is still presented; a
    // live read would have the sheet's content vanish out from under it for
    // the ~900ms before it dismisses itself. Item-based presentation is what
    // `shareItem` and `recapShareItem` already use for the same reason.
    @State private var infoAsset: IdentifiableAsset? = nil
    /// The memory whose day is being browsed. Item-based for the same reason
    /// as `infoAsset`: the pager must not drift out from under the sheet.
    @State private var dayRequest: IdentifiableAsset? = nil
    /// Whether the pager is showing memories or one whole day.
    ///
    /// Day mode swaps the pager's contents rather than presenting a second
    /// viewer over the first. Two live viewers would mean two `AVPlayer`s and
    /// two claims on the shared audio session, and a SwiftUI view whose body
    /// can contain itself needs `AnyView` erasure or a duplicated pager.
    @State private var pagerSource: PagerSource = .memories
    /// The memories the pager held before day mode, so returning does not
    /// depend on re-deriving them. Kept filtered by every removal, so a photo
    /// deleted while browsing the day cannot come back on the way out.
    @State private var memoriesSnapshot: [PHAsset] = []
    /// Which memory to land on when leaving day mode. An identifier, not an
    /// index: indices shift under deletes.
    @State private var memoriesAnchor: String? = nil
    /// Roughly how many items that day holds. Gates whether the control is
    /// offered; never displayed — see `DayContents.approximateCount`.
    @State private var dayItemCount = 0
    /// The mode the paging haptic last fired in, so a level change is not
    /// mistaken for a swipe.
    @State private var lastHapticSource: PagerSource = .memories
    @State private var shareTask: Task<Void, Never>? = nil
    @State private var isDeleting = false
    @State private var isPreparingShare = false
    @State private var shareError: String? = nil
    private enum PagerSource: Equatable {
        case memories
        case day

        var isDay: Bool { self == .day }
    }

    /// What the day probe watches: which memory is on screen *and* which mode
    /// the pager is in.
    private var dayProbeKey: String {
        "\(pagerSource.isDay ? "day" : "memories")#\(currentAssetIdentifier ?? "-")"
    }

    /// Indices of the pages that are actually built: the current one and its
    /// immediate neighbours, so a swipe has somewhere to swipe to.
    private var pageWindow: [Int] {
        guard !visibleAssets.isEmpty else { return [] }
        let lower = max(currentIndex - 1, 0)
        let upper = min(currentIndex + 1, visibleAssets.count - 1)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    private var currentAssetIsVideo: Bool {
        visibleAssets.indices.contains(currentIndex) && visibleAssets[currentIndex].mediaType == .video
    }
    /// Drives the location lookup. Keying on the identifier rather than the
    /// index means a delete, which shifts every index after it, re-resolves
    /// only when the memory on screen actually changed.
    private var currentAssetIdentifier: String? {
        visibleAssets.indices.contains(currentIndex) ? visibleAssets[currentIndex].localIdentifier : nil
    }
    /// What is currently over the viewer.
    ///
    /// `ViewerOverlays` has no default values, so adding a case to it breaks
    /// this line until it is filled in. That is deliberate: this rule was
    /// previously a hand-maintained `||` chain, and twice a new modal was
    /// added without being added to the chain — the second time leaving a
    /// video playing audibly underneath "Couldn't Share". A comment claiming
    /// the list was complete is what stood in for a check, and it was wrong.
    private var overlays: ViewerOverlays {
        ViewerOverlays(
            deleteConfirmation: showDeleteConfirm,
            shareSheet: shareItem != nil,
            deleteFailureAlert: deleteError != nil,
            shareFailureAlert: shareError != nil,
            infoSheet: infoAsset != nil,
            daySheet: dayRequest != nil,
            preparingShare: isPreparingShare,
            deleting: isDeleting
        )
    }

    private var isPlaybackBlocked: Bool { overlays.blocksPlayback }

    init(asset: PHAsset, allAssets: [PHAsset]) {
        self.asset = asset
        self.allAssets = allAssets
        _visibleAssets = State(initialValue: allAssets)
        _currentIndex = State(initialValue: allAssets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if visibleAssets.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                        .symbolEffect(.bounce, options: .nonRepeating)
                    Text("All memories removed")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .transition(.opacity)
            } else {
                GeometryReader { geo in
                    let pageWidth = geo.size.width
                    // Only the current page and its immediate neighbours are
                    // built.
                    //
                    // This was a plain HStack over `visibleAssets`, which is
                    // every asset from every year group, not just one year. So
                    // opening the viewer constructed a FullResAssetView for all
                    // of them up front — and because `dragOffset` is @State on
                    // this view, every one of those bodies re-evaluated on every
                    // frame of every swipe. On a large library with a widened
                    // memory range that is hundreds of views per frame.
                    //
                    // A LazyHStack would not fix it: it only lazifies inside a
                    // scroll container, and this is a hand-rolled pager driven
                    // by .offset and a DragGesture. Windowing the ForEach is
                    // the fix that keeps that gesture code untouched.
                    //
                    // Identity is by absolute index. FullResAssetView's
                    // .task(id:) keys on the asset's localIdentifier, so a view
                    // reused for a different asset after a delete reloads, and
                    // its .onDisappear releases the player when it leaves the
                    // window — the same cleanup `shouldRender: false` did.
                    ZStack(alignment: .leading) {
                        ForEach(pageWindow, id: \.self) { index in
                            FullResAssetView(
                                asset: visibleAssets[index],
                                isCurrent: index == currentIndex,
                                isPlaybackAllowed: !isPlaybackBlocked,
                                shouldRender: abs(index - currentIndex) <= 1,
                                showControls: showChrome,
                                onToggleChrome: {
                                    withAnimation {
                                        showChrome.toggle()
                                    }
                                },
                                onZoomStateChange: { isZoomed in
                                    if index == currentIndex {
                                        isCurrentAssetZoomed = isZoomed
                                    }
                                },
                                onScrubbingChanged: { isScrubbing in
                                    if index == currentIndex {
                                        isVideoScrubbing = isScrubbing
                                    }
                                }
                            )
                                .frame(width: pageWidth, height: geo.size.height)
                                .offset(x: CGFloat(index) * pageWidth)
                        }
                    }
                    .frame(width: pageWidth, height: geo.size.height, alignment: .leading)
                    .offset(x: -CGFloat(currentIndex) * pageWidth + dragOffset)
                    .gesture(pageDragGesture(pageWidth: pageWidth, isEnabled: !isCurrentAssetZoomed && !isVideoScrubbing && !isDeleting))
                }
            }

            if showChrome && !visibleAssets.isEmpty {
                // Lighter than before: the glass controls carry their own
                // legibility now, so the scrim only has to lift them off very
                // bright photos rather than dim the image.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showChrome && !visibleAssets.isEmpty {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        TCGlassContainer(spacing: 14) {
                            HStack(spacing: 10) {
                                ChromeButton(
                                    systemImage: "xmark",
                                    accessibilityLabel: "Close",
                                    action: { dismiss() }
                                )

                                Spacer(minLength: 6)

                                ChromeButton(
                                    systemImage: "square.and.arrow.up",
                                    accessibilityLabel: "Share memory",
                                    isBusy: isPreparingShare,
                                    action: shareCurrentPhoto
                                )
                                .disabled(isPreparingShare || isDeleting)

                                ChromeButton(
                                    systemImage: "trash",
                                    accessibilityLabel: "Delete memory",
                                    isBusy: isDeleting,
                                    action: { showDeleteConfirm = true }
                                )
                                .disabled(isDeleting || isPreparingShare)
                            }
                        }
                        .padding(.horizontal, 14)

                        // Deliberately outside the horizontal padding: the
                        // caption's band has to reach both screen edges so its
                        // only visible boundaries are the two feathered ones.
                        memoryCaption
                    }
                    .padding(.top, 6)

                    Spacer()

                    // The counter is centred on the screen rather than by
                    // balancing two equal-width buttons against each other. The
                    // row used to hold a trailing slideshow button whose only
                    // remaining job, once it was hidden for videos, was to act
                    // as counterweight so the capsule did not slide sideways.
                    // With the button gone a plain HStack would park the counter
                    // 27pt right of centre, so the centring is stated directly
                    // instead of being an emergent property of the contents.
                    TCGlassContainer(spacing: 14) {
                        ZStack {
                            Text("\(currentIndex + 1) of \(visibleAssets.count)")
                                .font(.footnote.weight(.medium))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .tcGlass(in: Capsule())

                            HStack {
                                ChromeButton(
                                    systemImage: "info.circle",
                                    accessibilityLabel: "Memory info",
                                    action: {
                                        guard visibleAssets.indices.contains(currentIndex) else { return }
                                        infoAsset = IdentifiableAsset(visibleAssets[currentIndex])
                                    }
                                )
                                .disabled(isDeleting || isPreparingShare)

                                Spacer(minLength: 6)

                                // The slot the removed slideshow button left
                                // behind. The control that goes into the day
                                // is replaced by the control that comes back
                                // out of it, so the ✕ keeps exactly one
                                // meaning — leave the viewer — at both levels.
                                if pagerSource.isDay {
                                    ChromeButton(
                                        systemImage: "chevron.backward",
                                        accessibilityLabel: "Back to this day's memories",
                                        action: returnToMemories
                                    )
                                    .disabled(isDeleting || isPreparingShare)
                                } else if dayItemCount > 1 {
                                    // Absent rather than disabled when there is
                                    // nothing else from that day: a control
                                    // that appears and then does nothing is
                                    // worse than one that was never there.
                                    ChromeButton(
                                        systemImage: "square.grid.2x2",
                                        accessibilityLabel: "See everything from that day",
                                        action: openDay
                                    )
                                    .disabled(isDeleting || isPreparingShare)
                                }
                            }
                            // The button is layered above the counter so it
                            // still wins hit testing if the capsule ever grows
                            // into it at the largest text sizes. Declaration
                            // order would then have VoiceOver read the counter
                            // first, so the leading-to-trailing order is
                            // restored explicitly rather than left to the ZStack.
                            .accessibilitySortPriority(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, currentAssetIsVideo ? 92 : 10)
                }
                .transition(.opacity)
            }

        }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                deleteCurrentPhoto()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the item to Recently Deleted in Photos, where it can still be recovered for a limited time.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(source: item.source, cleanupURLs: item.cleanupURLs)
        }
        .alert("Couldn't Delete", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "Something went wrong while moving the item to Recently Deleted.")
        }
        .alert("Couldn't Share", isPresented: shareErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "The memory could not be prepared for sharing.")
        }
        .sheet(item: $dayRequest) { wrapper in
            DayContextView(anchor: wrapper.asset) { asset, contents in
                enterDay(with: contents, focusing: asset)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $infoAsset) { wrapper in
            MemoryInfoSheet(
                asset: wrapper.asset,
                locationName: locationName,
                allowsExclusions: !pagerSource.isDay,
                onExcludePhoto: excludeCurrentPhoto,
                onExcludeAlbum: excludeAlbum,
                onExcludePlace: excludePlace
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Where a memory happened is part of remembering it, so the place name
        // resolves as each one comes into view rather than waiting to be asked
        // for. The pause coalesces a fast swipe through a day into one lookup
        // instead of one per photo, which matters because reverse geocoding is
        // rate limited; anywhere already seen comes back from the cache.
        .task(id: currentAssetIdentifier) {
            locationName = nil
            guard visibleAssets.indices.contains(currentIndex),
                  let coordinate = visibleAssets[currentIndex].location?.coordinate else { return }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            let resolved = await PlaceNameLookup.shared.placeName(for: coordinate)
            guard !Task.isCancelled else { return }
            locationName = resolved
        }
        // Keyed on which memory is on screen, not on its position.
        //
        // The index is the wrong key in both directions. A delete can leave
        // the index untouched while a different photo slides into it, and
        // nothing reset — which is how a zoomed photo could leave the page
        // gesture disabled. A delete further back changes the index while the
        // photo on screen does not, and everything reset for no reason.
        //
        // It is also the key that keeps working when the pager's contents are
        // replaced rather than shrunk.
        .onChange(of: currentAssetIdentifier) { _, _ in
            resetPerPageState()
        }
        // Whether this memory's day holds anything else.
        //
        // Everything the answer depends on is read *before* the await. A
        // `.task(id:)` closure captures the View struct as it was when the
        // task started, so a value read afterwards would belong to whichever
        // memory was on screen when the user tapped, not to the one they have
        // swiped to since.
        // Keyed on the mode as well as the asset.
        //
        // Keyed on the asset alone, the most natural interaction in the whole
        // feature broke it: the anchor tile is highlighted and scrolled to, so
        // people tap the photo they were already on. That leaves
        // `currentAssetIdentifier` unchanged through both the entry and the
        // exit, so the probe never re-ran, `dayItemCount` stayed at the zero
        // `enterDay` set, and the control vanished for that memory with no way
        // back to it but swiping away and returning.
        .task(id: dayProbeKey) {
            dayItemCount = 0
            guard !pagerSource.isDay,
                  visibleAssets.indices.contains(currentIndex),
                  let date = visibleAssets[currentIndex].creationDate else { return }

            // Debounced like the place-name lookup, so a fast swipe through
            // twenty memories does not queue twenty day queries.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            let count = await loadDayApproximateCount(containing: date)
            guard !Task.isCancelled else { return }
            dayItemCount = count
        }
        // Paging feedback, which genuinely does belong to the movement rather
        // than to the page: a delete that shifts the index should still feel
        // like the deck moved.
        .onChange(of: currentIndex) { _, _ in
            // Not when the index jumped because the pager changed level:
            // entering or leaving a day moves it by a hundred and is not a
            // page turn.
            guard pagerSource == lastHapticSource else {
                lastHapticSource = pagerSource
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .onDisappear {
            shareTask?.cancel()
            // Leaving the viewer is the only point at which no video can be
            // playing, so it is the right place to hand audio back to whatever
            // the user was listening to before.
            VideoAudioSession.end()
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(named: "Previous memory") {
            moveToPreviousMemory()
        }
        .accessibilityAction(named: "Next memory") {
            moveToNextMemory()
        }
    }

    /// Date and place, on their own full-width row rather than wedged between
    /// the buttons. In the shared row the capsule got roughly 143pt of text on a
    /// 393pt phone against a date that wants 140 — so the date wrapped, the
    /// wrapped text then reported only its longest line as its width, and the
    /// place name (which has no minimum width of its own, being single-line and
    /// truncating) collapsed into whatever was left: "South Cha…". On its own
    /// row the same text has ~337pt, which is headroom rather than a margin.
    ///
    /// No glass here on purpose. This is a label, not a control, and glass is
    /// the material of the control layer; it also used to change height every
    /// time a place name resolved, which made the capsule visibly wobble.
    @ViewBuilder
    private var memoryCaption: some View {
        // Bounds-checked: a delete can retire the index between the emptiness
        // guard above and this read.
        if visibleAssets.indices.contains(currentIndex),
           let date = visibleAssets[currentIndex].creationDate {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Was .white.opacity(0.75), which was its own defect: partial
                // white composites toward the background, so over a blown-out
                // sky the text was rendering at 252 against 245 — it was not
                // merely hard to read, it was becoming the photo. Size and
                // weight carry the hierarchy instead.
                Text(captionDetail(for: date))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Edge definition only. A blurred shadow is a low-pass effect, so it
            // helps against smooth backgrounds like sky and does nothing against
            // foliage, whose detail sits at the same spatial frequency as the
            // letter strokes. The band below is what makes this readable; this
            // just keeps the edges crisp against whatever survives it.
            .shadow(color: .black.opacity(0.7), radius: 1.2, y: 0.5)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(captionScrim)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: locationName)
            // Nothing here is tappable, and it sits directly over the pager. Left
            // hit-testable it would swallow both the swipe to the next memory and
            // the tap that dismisses the chrome, in a band the old glass capsule
            // only occupied a fraction of. VoiceOver is unaffected by this.
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    /// The one thing that actually guarantees the caption is readable.
    ///
    /// The top scrim does not reach it: that gradient is 140pt measured from the
    /// physical top of the screen, and with the safe area, the button row and
    /// the spacing above it the caption starts around 117pt — where 0.38 alpha
    /// has decayed to about 0.06 — and its second line falls past 140pt
    /// entirely. So the caption had no background at all.
    ///
    /// Darkening is what fixes that, and it has to be sized against the
    /// brightest pixel a photo can put here rather than the average one: 0.58
    /// black holds even a blown-out white sky to roughly 5:1 for both lines,
    /// which is a bound that holds for any image rather than a bet on most of
    /// them. It reaches both screen edges and feathers top and bottom, so there
    /// is no rectangle and no corner radius anywhere — it reads as light falling
    /// off, not as a panel laid on the photograph. Over a dark or letterboxed
    /// photo it is invisible, because black over black changes nothing.
    private var captionScrim: some View {
        Group {
            if reduceTransparency {
                Color.black.opacity(0.85)
            } else {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.58), location: 0.3),
                        .init(color: .black.opacity(0.58), location: 0.7),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// The secondary caption line. It always says something, which is the point:
    /// a memory with no GPS leaves no hole, and a place name arriving after its
    /// network round trip appends to a line that already exists instead of
    /// inserting a new one — the caption widens rather than shifting the layout.
    private func captionDetail(for date: Date) -> String {
        let years = MemoryWindow.yearsAgo(for: date)
        // A memory from this same year has no anniversary to report, so the
        // clock time is the only thing left worth saying about when it happened.
        let lead = years > 0
            ? "\(years) year\(years == 1 ? "" : "s") ago"
            : date.formatted(date: .omitted, time: .shortened)

        guard let locationName else { return lead }
        return "\(lead) · \(locationName)"
    }

    private func pageDragGesture(pageWidth: CGFloat, isEnabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: isEnabled ? 15 : .greatestFiniteMagnitude)
            .onChanged { value in
                guard isEnabled else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    // Animated, because this can fire mid-drag when a swipe
                    // turns vertical. Assigning zero outright teleported the
                    // photo back to centre.
                    if dragOffset != 0 {
                        withAnimation(Self.pageAnimation) { dragOffset = 0 }
                    }
                    return
                }

                let slop = dragActivationSlop ?? value.translation.width
                if dragActivationSlop == nil { dragActivationSlop = slop }
                let proposed = value.translation.width - slop

                let atFirst = currentIndex == 0 && proposed > 0
                let atLast = currentIndex == visibleAssets.count - 1 && proposed < 0
                if atFirst || atLast {
                    dragOffset = Self.rubberBanded(proposed, limit: pageWidth)
                } else {
                    dragOffset = proposed
                }
            }
            .onEnded { value in
                let slop = dragActivationSlop ?? 0
                dragActivationSlop = nil

                guard isEnabled else {
                    dragOffset = 0
                    return
                }
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(Self.pageAnimation) { dragOffset = 0 }
                    return
                }

                let threshold = pageWidth * 0.2
                let predicted = value.predictedEndTranslation.width - slop
                var newIndex = currentIndex

                if predicted < -threshold && currentIndex < visibleAssets.count - 1 {
                    newIndex += 1
                } else if predicted > threshold && currentIndex > 0 {
                    newIndex -= 1
                }

                withAnimation(Self.pageAnimation) {
                    currentIndex = newIndex
                    dragOffset = 0
                }
            }
    }

    /// How a page settles once the finger lifts.
    ///
    /// Measured, not guessed. Screen recordings of this viewer and of Apple's
    /// Photos were compared frame by frame: Photos never moves the page faster
    /// than about 15 px per frame and takes 0.5–0.7s over a swipe, while this
    /// viewer peaked at 21 and twice moved so far between two frames that the
    /// measurement could not follow it — most of the screen in a single frame.
    ///
    /// That comparison also killed the idea the previous version was built on.
    /// Photos' deceleration is very nearly the same length however hard the
    /// flick was: velocity decides whether the page turns, not how quickly it
    /// arrives. Scaling the spring's response by velocity therefore made the
    /// hardest flicks land fastest — precisely backwards, and the harder
    /// someone swiped the more abrupt the app felt.
    ///
    /// So: one response, and a slow one. Damped just under 1 so it never
    /// overshoots, because a photo bouncing past its edge reads as a bug
    /// rather than as momentum. `blendDuration` is 0 so an interrupted swipe
    /// picks up from where the page actually is instead of cross-fading.
    private static let pageAnimation: Animation =
        .spring(response: 0.48, dampingFraction: 0.88, blendDuration: 0)

    /// Resistance at the first and last page.
    ///
    /// Was a flat `proposed * 0.3`, which is linear: it resists identically
    /// at one point of travel and at three hundred, so the edge feels like a
    /// slow drag rather than like something pulling back. This is the curve
    /// UIScrollView uses — resistance grows with distance and the offset
    /// approaches `limit` without ever reaching it.
    private static func rubberBanded(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let magnitude = abs(distance)
        let resisted = (1 - (1 / (magnitude * 0.55 / limit + 1))) * limit
        return distance < 0 ? -resisted : resisted
    }

    /// Builds the share payload.
    ///
    /// The memory is handed over as a *single* attachment. It used to go out as
    /// two — the media plus a caption string — and a share sheet given two
    /// attachments hands both to the receiving extension, which then has to
    /// decide which one it is being asked to post. Extensions that expect a
    /// single movie can pick the wrong one and present an empty composer, which
    /// is what Snapchat does with a video from here. The caption survives as
    /// metadata on the item rather than as a second attachment: it becomes the
    /// mail subject and the title shown in the share sheet header, neither of
    /// which is an attachment an extension has to disambiguate.
    private func shareCurrentPhoto() {
        guard currentIndex < visibleAssets.count, !isPreparingShare, !isDeleting else { return }
        let asset = visibleAssets[currentIndex]
        let caption = shareCaption(for: asset)
        isPreparingShare = true
        shareError = nil

        // Clears anything a previous run left behind before adding to it.
        // Detached because this walks and deletes files: under this target's
        // default MainActor isolation a bare call would do that synchronously
        // on the main thread, on every share tap.
        Task.detached(priority: .utility) {
            sweepStaleShareExports()
        }

        let isVideo = asset.mediaType == .video
        shareTask?.cancel()
        shareTask = Task {
            if isVideo {
                // A video has no image to stand in for it in the sheet header,
                // so a poster frame is fetched alongside the export. It runs
                // concurrently because it is decorative — a failure here must
                // not fail the share, and it must not delay it either.
                async let poster = loadImage(
                    from: asset,
                    targetSize: CGSize(width: 400, height: 400),
                    contentMode: .aspectFit
                )
                let videoURL = await exportVideoToTemporaryFile(from: asset)
                let thumbnail = await poster
                await MainActor.run {
                    finishShare(
                        for: asset,
                        caption: caption,
                        poster: thumbnail,
                        result: videoURL.map { .video($0) },
                        failureMessage: "The video could not be downloaded or exported. Check its iCloud availability and try again."
                    )
                }
            } else {
                let image = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit
                )
                await MainActor.run {
                    finishShare(
                        for: asset,
                        caption: caption,
                        // A photo is its own preview — no second fetch.
                        poster: image,
                        result: image.map { .photo($0) },
                        failureMessage: "The photo could not be downloaded. Check its iCloud availability and try again."
                    )
                }
            }
        }
    }

    private enum PreparedShare {
        case video(URL)
        case photo(UIImage)
    }

    /// Single exit point for the share task.
    ///
    /// An earlier version cleared `isPreparingShare` on the success path and on
    /// the uncancelled-failure path but not when the work both failed and was
    /// cancelled, which left the spinner running and — because
    /// `isPreparingShare` feeds `isPlaybackBlocked` — left video playback dead
    /// until the user swiped away. Clearing it unconditionally fixed that and
    /// introduced the opposite bug: a superseded task finishing late would
    /// clear the flag belonging to the share that replaced it (share a video,
    /// swipe, share again, and the first export lands mid-second-export,
    /// stopping its spinner and re-enabling the button).
    ///
    /// So it is cleared only when this task still owns the flag. Every site
    /// that cancels the task resets the flag itself — `resetPerPageState()`
    /// does, and so does `deleteCurrentPhoto()` before it starts, and
    /// `onDisappear` is tearing the view down — so a cancelled task has
    /// nothing left to clean up here.
    private func finishShare(
        for asset: PHAsset,
        caption: String,
        poster: UIImage?,
        result: PreparedShare?,
        failureMessage: String
    ) {
        if !Task.isCancelled {
            isPreparingShare = false
        }

        // The memory on screen changed while the export was running, so this
        // payload is no longer the one the user asked for.
        let stillCurrent = visibleAssets.indices.contains(currentIndex)
            && visibleAssets[currentIndex].localIdentifier == asset.localIdentifier

        guard let result else {
            if stillCurrent, !Task.isCancelled {
                shareError = failureMessage
            }
            return
        }

        guard stillCurrent, !Task.isCancelled else {
            if case .video(let url) = result {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        switch result {
        case .video(let url):
            shareItem = ShareItem(
                source: MemoryShareItemSource(item: url, caption: caption, poster: poster),
                cleanupURLs: [url]
            )
        case .photo(let image):
            shareItem = ShareItem(
                source: MemoryShareItemSource(item: image, caption: caption, poster: poster)
            )
        }
    }

    private func deleteCurrentPhoto() {
        guard currentIndex < visibleAssets.count, !isDeleting else { return }
        let assetToDelete = visibleAssets[currentIndex]
        let identifier = assetToDelete.localIdentifier
        let identifiers = visibleAssets.map(\.localIdentifier)
        let nextIndex = GalleryStateLogic.indexAfterDeleting(
            identifier: identifier,
            from: identifiers,
            currentIndex: currentIndex
        )
        isDeleting = true
        shareTask?.cancel()
        isPreparingShare = false

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([assetToDelete] as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                isDeleting = false
                if success {
                    // Both arrays, always. The snapshot is what day mode
                    // returns to, and a delete performed in day mode would
                    // otherwise put the photo back on the way out.
                    memoriesSnapshot.removeAll { $0.localIdentifier == identifier }
                    withAnimation {
                        visibleAssets.removeAll { $0.localIdentifier == identifier }
                        if let nextIndex {
                            // Clamped, because `nextIndex` was computed from
                            // the list as it stood before this delete was
                            // confirmed. An exclusion landing in that window
                            // removes further items, and an index past the
                            // end leaves `pageWindow` empty — a black screen
                            // with no way out.
                            currentIndex = min(max(nextIndex, 0), max(visibleAssets.count - 1, 0))
                        }
                    }

                    NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)

                    if visibleAssets.isEmpty {
                        if pagerSource.isDay {
                            // Emptying the day is not emptying the viewer.
                            // Dropping the user all the way out to the gallery
                            // would skip the level they came from.
                            returnToMemories()
                        } else {
                            scheduleDismissIfStillEmpty()
                        }
                    }
                } else {
                    deleteError = error?.localizedDescription ?? "Could not move this item to Recently Deleted."
                }
            }
        }
    }

    /// "Feature this less often." Three ways in, one way out: whatever just
    /// got excluded, `applyExclusionRemoval` re-derives the current exclusion
    /// state from scratch and filters `visibleAssets` against it, rather than
    /// each call site trying to know which of *its own* assets just became
    /// hidden. That keeps this surface, the grid, and tomorrow's notification
    /// count reading the one definition in `MemoryExclusions`.
    private func excludeCurrentPhoto() {
        // From `infoAsset`, the asset the open sheet is actually showing,
        // rather than `visibleAssets[currentIndex]` — the two cannot drift
        // apart today since the pager cannot be swiped behind a presented
        // sheet, but this makes that guarantee unnecessary rather than relied
        // on.
        guard let asset = infoAsset?.asset else { return }
        MemoryExclusions.excludeAsset(asset)
        applyExclusionRemoval()
    }

    private func excludeAlbum(_ collection: PHAssetCollection) {
        MemoryExclusions.excludeAlbum(collection)
        applyExclusionRemoval()
    }

    private func excludePlace(coordinate: CLLocationCoordinate2D, label: String) {
        MemoryExclusions.excludePlace(near: coordinate, label: label)
        applyExclusionRemoval()
    }

    /// `MemoryExclusions.Context.current()` is cheap for a photo or a place,
    /// but excluding an album walks `PHAsset.fetchAssets(in:)` over every one
    /// of its members — thousands, for someone's "Camera Roll"-sized album.
    /// `NotificationManager` already does this same resolution off the main
    /// actor; doing it inline here on a Button action would freeze the
    /// pager for exactly as long as that album takes to enumerate.
    /// Everything here is read *after* the await, not captured before it.
    ///
    /// Resolving the context is deliberately slow for an album — that is why
    /// it is off the main actor — and the viewer stays fully interactive
    /// throughout: the info sheet is drag-dismissible, so the user can be
    /// back on the pager swiping and deleting long before this lands.
    /// Filtering a snapshot taken before the await and assigning it back
    /// wholesale therefore overwrote whatever happened in between. A photo
    /// deleted during that window reappeared in the pager and in the counter,
    /// and the index snapped back to wherever the user had been when they
    /// tapped. Filtering the live array instead cannot resurrect anything,
    /// because what is already gone is not in it to be re-admitted — which
    /// also makes two overlapping exclusions safe in either order.
    private func applyExclusionRemoval() {
        Task {
            let context = await resolvedExclusionContext()

            await MainActor.run {
                // The memories to return to are filtered whichever mode the
                // pager is in, so an exclusion made while browsing a day is
                // not undone on the way out.
                memoriesSnapshot = memoriesSnapshot.filter { !context.excludes($0) }

                // A day is deliberately unfiltered — "Feature Less Often"
                // governs what Attic chooses to surface, not what exists, and
                // the point of the day view is that it matches the Photos app.
                // So in day mode the pager itself is left alone.
                guard !pagerSource.isDay else {
                    NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
                    return
                }

                let currentIdentifier = visibleAssets.indices.contains(currentIndex)
                    ? visibleAssets[currentIndex].localIdentifier
                    : nil
                let filtered = visibleAssets.filter { !context.excludes($0) }

                withAnimation {
                    visibleAssets = filtered
                    if filtered.isEmpty {
                        currentIndex = 0
                    } else if let currentIdentifier,
                              let index = filtered.firstIndex(where: { $0.localIdentifier == currentIdentifier }) {
                        currentIndex = index
                    } else {
                        currentIndex = min(max(currentIndex, 0), filtered.count - 1)
                    }
                }
                NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)

                if filtered.isEmpty {
                    scheduleDismissIfStillEmpty()
                }
            }
        }
    }

    /// Everything that belongs to the memory on screen rather than to the
    /// viewer.
    ///
    /// Four places used to reset some of this by hand, and the differences
    /// between them were not deliberate. The exclusion path cleared the zoom
    /// flag but not the scrubbing one — and `isVideoScrubbing` left true
    /// disables the page gesture (see `isEnabled:` where `pageDragGesture` is
    /// attached), so excluding a video while its scrubber was held left the
    /// pager unswipeable with no way to recover but closing the viewer. It
    /// also never cancelled an in-flight share, so the spinner could keep
    /// running for a memory that had just been removed.
    ///
    /// One function, called from one place, keyed on the identity of what is
    /// displayed. A fifth site cannot forget a fifth flag, because there are
    /// no other sites.
    private func resetPerPageState() {
        isCurrentAssetZoomed = false
        isVideoScrubbing = false
        shareTask?.cancel()
        isPreparingShare = false
        locationName = nil
        // Belt and braces: `onEnded` clears this, but a gesture that is
        // interrupted rather than ended — a zoom starting mid-swipe disables
        // it — never reaches `onEnded`, and a stale value would offset the
        // next swipe by however far the abandoned one had travelled.
        dragActivationSlop = nil
    }

    /// Close the viewer shortly, but only if it is still empty when the time
    /// comes.
    ///
    /// The delay exists so "All memories removed" is readable rather than a
    /// flash. Unguarded, it was a decision made on stale information: an
    /// exclusion resolving against a large album takes seconds, so the user
    /// could open a day and be paging through two hundred photos when a
    /// dismiss scheduled before any of that finally fired, closing the viewer
    /// for no reason they could connect to anything.
    private func scheduleDismissIfStillEmpty() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard visibleAssets.isEmpty else { return }
            dismiss()
        }
    }

    // MARK: - Day mode

    private func openDay() {
        guard visibleAssets.indices.contains(currentIndex) else { return }
        dayRequest = IdentifiableAsset(visibleAssets[currentIndex])
    }

    /// Swap the pager over to the whole day, landing on the tapped item.
    ///
    /// The snapshot is taken only on the way *in*, so tapping a second tile
    /// while already in day mode re-targets without overwriting the memories
    /// to come back to.
    private func enterDay(with contents: DayContents.Result, focusing asset: PHAsset) {
        // Resolved by identity, and a miss refuses rather than falling back to
        // zero. The day set is not a subset of the memories: it contains
        // photos outside the anniversary window and photos the user asked to
        // feature less often. A `?? 0` here would silently open a different
        // photo and label it "1 of 250".
        guard let index = contents.assets.firstIndex(where: {
            $0.localIdentifier == asset.localIdentifier
        }) else {
            dayRequest = nil
            return
        }

        if !pagerSource.isDay {
            memoriesSnapshot = visibleAssets
            memoriesAnchor = currentAssetIdentifier
        }

        // Contents first, sheet last: the swap and the playback unblock then
        // land in one update pass, rather than briefly resuming the outgoing
        // video before the page it belongs to is replaced.
        visibleAssets = contents.assets
        currentIndex = index
        pagerSource = .day
        dayItemCount = 0
        dayRequest = nil
    }

    /// Back to the memories, at the one the user left from.
    ///
    /// Restores the snapshot rather than re-deriving the memories, because
    /// re-deriving cannot see what happened while the day was open. The
    /// snapshot is filtered by every removal as it happens, so it cannot
    /// resurrect a photo that was deleted in day mode — the same reasoning
    /// as `applyExclusionRemoval` filtering the live array.
    private func returnToMemories() {
        guard pagerSource.isDay else { return }

        let restored = memoriesSnapshot
        pagerSource = .memories
        memoriesSnapshot = []

        guard !restored.isEmpty else {
            // Every memory was removed while the day was open. Same ending as
            // deleting the last one from the pager.
            visibleAssets = []
            currentIndex = 0
            memoriesAnchor = nil
            scheduleDismissIfStillEmpty()
            return
        }

        let index = memoriesAnchor
            .flatMap { identifier in
                restored.firstIndex { $0.localIdentifier == identifier }
            }
            // Not the current index: that is a position in a 250-item day and
            // means nothing in the memories. Clamping it would land the user
            // at the end of their memories for no reason they could follow.
            ?? 0

        visibleAssets = restored
        currentIndex = index
        memoriesAnchor = nil
    }

    private func moveToPreviousMemory() {
        guard !isDeleting, currentIndex > 0 else { return }
        withAnimation(Self.pageAnimation) { currentIndex -= 1 }
    }

    private func moveToNextMemory() {
        guard !isDeleting, currentIndex < visibleAssets.count - 1 else { return }
        withAnimation(Self.pageAnimation) { currentIndex += 1 }
    }

    private func shareCaption(for asset: PHAsset) -> String {
        guard let creationDate = asset.creationDate else { return "An Attic memory" }
        let years = MemoryWindow.yearsAgo(for: creationDate)
        guard years > 0 else { return "An Attic memory" }
        let timing = MemoryWindow.dayWindow > 0 ? "around this day" : "today"
        return "\(years) year\(years == 1 ? "" : "s") ago \(timing)"
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )
    }
}

/// Circular glass control for the viewer chrome. Glass is the right material
/// here specifically because it floats over full-bleed media — the case Apple
/// designed it for — and it keeps the photo readable underneath.
private struct ChromeButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .tcGlassButtonStyle(isProminent: false)
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MemoryInfoSheet: View {
    let asset: PHAsset
    let locationName: String?
    /// Hidden in day mode.
    ///
    /// "Feature Less Often" governs which memories Attic surfaces, and a day
    /// is deliberately unfiltered — so excluding from here changed nothing
    /// visible and the photo stayed exactly where it was. There is no way to
    /// tell that apart from a failure, so people do it again. Worse, an
    /// exclusion that emptied the memories behind the day meant the back
    /// arrow later dropped them straight out of the viewer, as though one tap
    /// had destroyed everything.
    let allowsExclusions: Bool
    let onExcludePhoto: () -> Void
    let onExcludeAlbum: (PHAssetCollection) -> Void
    let onExcludePlace: (CLLocationCoordinate2D, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition
    @State private var handoff: HandoffState = .idle
    @State private var exif: PhotoEXIF? = nil
    @State private var exclusionConfirmation: String? = nil
    @State private var pendingAction: PendingExclusion? = nil
    @State private var containingAlbums: [PHAssetCollection] = []
    /// Collapsed at rest. Six rows of camera settings pushed the map and
    /// "Feature Less Often" below the fold on every photo, for information
    /// most people want once and not every time.
    ///
    /// Nothing resets this on a swipe because nothing has to: the sheet is
    /// presented with `.sheet(item:)` and blocks the pager while it is up, so
    /// each memory gets a freshly built view with this back at false.
    @State private var showsCameraDetails = false

    private enum HandoffState {
        case idle
        case working
        case done(PhotosEditHandoff.Outcome)
        case failed(String)
    }

    private enum PendingExclusion: Identifiable {
        case photo
        case place
        case album(PHAssetCollection)

        var id: String {
            switch self {
            case .photo: return "photo"
            case .place: return "place"
            case .album(let collection): return "album-\(collection.localIdentifier)"
            }
        }
    }

    init(
        asset: PHAsset,
        locationName: String?,
        allowsExclusions: Bool = true,
        onExcludePhoto: @escaping () -> Void,
        onExcludeAlbum: @escaping (PHAssetCollection) -> Void,
        onExcludePlace: @escaping (CLLocationCoordinate2D, String) -> Void
    ) {
        self.asset = asset
        self.locationName = locationName
        self.allowsExclusions = allowsExclusions
        self.onExcludePhoto = onExcludePhoto
        self.onExcludeAlbum = onExcludeAlbum
        self.onExcludePlace = onExcludePlace
        let center = asset.location?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        _mapPosition = State(initialValue: .region(region))
    }

    private var yearsAgoLabel: String? {
        guard let date = asset.creationDate else { return nil }
        let yearsAgo = MemoryWindow.yearsAgo(for: date)
        guard yearsAgo > 0 else { return nil }
        return yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    if let yearsAgoLabel {
                        Text(yearsAgoLabel.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.3)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .complete, time: .omitted))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    infoRow(
                        label: "Kind",
                        value: asset.mediaType == .video ? "Video" : "Photo",
                        icon: asset.mediaType == .video ? "video" : "photo"
                    )
                    Divider().padding(.leading, 40)
                    infoRow(
                        label: "Dimensions",
                        value: "\(asset.pixelWidth) × \(asset.pixelHeight)",
                        icon: "aspectratio"
                    )
                    if asset.mediaType == .video {
                        Divider().padding(.leading, 40)
                        infoRow(
                            label: "Duration",
                            value: formattedDuration(asset.duration),
                            icon: "timer"
                        )
                    }
                    if let locationName {
                        Divider().padding(.leading, 40)
                        infoRow(label: "Location", value: locationName, icon: "location")
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let exif {
                    cameraSection(exif)
                }

                editHandoffSection

                if let coordinate = asset.location?.coordinate {
                    Map(position: $mapPosition, interactionModes: [.zoom, .pan]) {
                        Marker("Memory Location", coordinate: coordinate)
                            .tint(.red)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)

                    Text("The location name is requested from Apple's Maps service using this photo's coordinates. The coordinates come from the photo itself — Attic never asks for your current location.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if allowsExclusions {
                    featureLessOftenSection
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: asset.localIdentifier) {
            exif = nil
            // Reset alongside `exif`, which this already did. Leaving it
            // behind meant a previous photo's "Pinned." could sit under a
            // different memory if the sheet were ever reused for another
            // asset.
            handoff = .idle
            containingAlbums = await albumsContaining(asset)
            guard asset.mediaType == .image else { return }
            exif = await photoEXIF(for: asset)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: isPendingActionPresented,
            titleVisibility: .visible
        ) {
            Button("Feature Less Often", role: .destructive) {
                confirmPendingExclusion()
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("You can undo this later from Settings → Featured Less Often.")
        }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .photo:
            return "Feature this photo less often?"
        case .place:
            return "Feature this place less often?"
        case .album(let collection):
            let name = collection.localizedTitle?.isEmpty == false ? collection.localizedTitle! : "this album"
            return "Feature \(name) less often?"
        case nil:
            return ""
        }
    }

    private var isPendingActionPresented: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private func confirmPendingExclusion() {
        guard let pendingAction else { return }
        switch pendingAction {
        case .photo:
            onExcludePhoto()
            exclusionConfirmation = "Won't feature this photo again"
        case .place:
            if let coordinate = asset.location?.coordinate {
                onExcludePlace(coordinate, Self.placeLabel(for: coordinate, resolvedName: locationName))
                exclusionConfirmation = "Won't feature this place as often"
            }
        case .album(let collection):
            onExcludeAlbum(collection)
            exclusionConfirmation = "Won't feature this album as often"
        }
        self.pendingAction = nil
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        }
    }

    /// The name this place is remembered by in Settings.
    ///
    /// The resolved name is preferred, but it arrives asynchronously and
    /// `PlaceNameLookup` deliberately returns nothing when offline or rate
    /// limited — while this row is tappable immediately. Falling back to a
    /// fixed string meant two exclusions in two different cities both showed
    /// up as "This location", indistinguishable and never repaired.
    /// Coordinates are not pretty, but they identify the place.
    private static func placeLabel(
        for coordinate: CLLocationCoordinate2D,
        resolvedName: String?
    ) -> String {
        if let resolvedName, !resolvedName.isEmpty { return resolvedName }
        return String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
    }

    /// EXIF is genuinely useless once formatting fails on every field, which
    /// is common for screenshots and downloaded images — no camera made
    /// them — so the section only appears when there is something to say.
    /// Built as a list first, then drawn with separators *between* entries.
    ///
    /// Each row used to decide for itself whether to draw a leading divider
    /// by naming the rows above it, and the later ones simply drew one
    /// unconditionally — so a photo carrying an exposure time but no camera,
    /// lens or aperture (a re-exported or partly stripped file) opened the
    /// card with a divider across the top and nothing above it. Deriving the
    /// separators from the list makes that unrepresentable.
    ///
    /// "Focal Length (35 mm)" says which focal length it is. The value comes
    /// from the 35mm-equivalent EXIF tag, so a 50mm lens on an APS-C body
    /// reads 75 — correct, and baffling under a bare "Focal Length".
    private func cameraSection(_ exif: PhotoEXIF) -> some View {
        let rows: [(label: String, value: String, icon: String)] = [
            exif.cameraModel.map { (label: "Camera", value: $0, icon: "camera") },
            exif.lensModel.map { (label: "Lens", value: $0, icon: "camera.aperture") },
            exif.apertureDisplay.map { (label: "Aperture", value: $0, icon: "camera.aperture") },
            exif.shutterSpeedDisplay.map { (label: "Shutter Speed", value: $0, icon: "timer") },
            exif.isoDisplay.map { (label: "ISO", value: $0, icon: "sun.max") },
            exif.focalLengthDisplay.map { (label: "Focal Length (35 mm)", value: $0, icon: "camera.macro") }
        ].compactMap { $0 }

        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    showsCameraDetails.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, alignment: .center)
                    Text("Camera Details")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("\(rows.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsCameraDetails ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Camera details")
            .accessibilityValue(showsCameraDetails ? "Expanded" : "Collapsed")
            .accessibilityHint(showsCameraDetails ? "Double tap to hide" : "Double tap to show")

            if showsCameraDetails {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().padding(.leading, 40)
                    infoRow(label: row.label, value: row.value, icon: row.icon)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Person" is deliberately not one of the three options here. PhotoKit
    /// never hands third-party apps the named People it detects — that stays
    /// internal to Photos.app — so there is no API this could be built on
    /// short of Attic doing its own on-device face-identity clustering. Album
    /// and place are the two exclusion axes that are actually implementable
    /// without that.
    @ViewBuilder
    private var featureLessOftenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Feature Less Often")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                exclusionRow(title: "This Photo", icon: "photo") {
                    pendingAction = .photo
                }

                if asset.location != nil {
                    Divider().padding(.leading, 40)
                    exclusionRow(title: "This Place", icon: "location.slash") {
                        pendingAction = .place
                    }
                }

                if !containingAlbums.isEmpty {
                    Divider().padding(.leading, 40)
                    Menu {
                        ForEach(containingAlbums, id: \.localIdentifier) { collection in
                            Button(collection.localizedTitle ?? "Untitled Album") {
                                pendingAction = .album(collection)
                            }
                        }
                    } label: {
                        exclusionRowLabel(title: "This Album", icon: "rectangle.stack.badge.minus")
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let exclusionConfirmation {
                Label {
                    Text(exclusionConfirmation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: exclusionConfirmation)
    }

    private func exclusionRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            exclusionRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func exclusionRowLabel(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// "Take me to this one in Photos so I can edit it."
    ///
    /// iOS has no public way to open the Photos app at a specific asset, so
    /// this does the next best thing and makes the memory trivial to find once
    /// the user gets there — see `PhotosEditHandoff` for why the direct route
    /// does not exist. The copy is deliberately explicit about where to look,
    /// because a vague confirmation would leave the user hunting anyway.
    @ViewBuilder
    /// Where this memory lives, and a way to make it findable.
    ///
    /// This used to be a single button reading "Send to Photos for Editing",
    /// which was wrong in both halves. Nothing is sent: an album holds
    /// references, so there is exactly one of each photo before and after.
    /// And what someone asking this question usually wants is not the editor —
    /// it is to know where their own photo actually lives. The sheet already
    /// loads the user's own album names for this asset, so it can simply say
    /// so, which is a better answer than any button.
    private var editHandoffSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find This in Photos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                if let albums = ownAlbumNames {
                    infoRow(label: "In your album", value: albums, icon: "rectangle.stack")
                    Divider().padding(.leading, 40)
                }

                if let date = asset.creationDate {
                    infoRow(
                        label: "Taken",
                        value: date.formatted(date: .abbreviated, time: .shortened),
                        icon: "calendar"
                    )
                    Divider().padding(.leading, 40)
                }

                Button(action: stageForEditing) {
                    HStack(spacing: 12) {
                        Image(systemName: "pin")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pin for Photos")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Puts it alone in an album called \(PhotosEditHandoff.albumTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)

                        Spacer(minLength: 12)

                        if isWorking {
                            ProgressView()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pin for Photos")
                .accessibilityHint("Puts this memory on its own in an album called \(PhotosEditHandoff.albumTitle), so you can find it in the Photos app")
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            if let outcome = handoffResult {
                Label {
                    Text(outcome)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.footnote)
                // The arrow reads unreliably under VoiceOver, so the spoken
                // version spells the path out.
                .accessibilityLabel(spokenHandoffResult ?? outcome)
                .transition(.opacity)
            }

            if case .failed(let message) = handoff {
                Label {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .transition(.opacity)
            }

            Text("Attic never copies your photos. There is only ever one of each, in your own library.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Keyed on the whole state, not on `isWorking`: a retry that goes from
        // one failure straight to another leaves `isWorking` unchanged, so the
        // new message used to appear with no transition at all.
        .animation(.easeInOut(duration: 0.2), value: handoffAnimationKey)
        // VoiceOver does not announce a view that simply appears mid-screen,
        // so tapping the button was silent for anyone not watching the
        // checkmark.
        .onChange(of: handoffAnimationKey) { _, _ in
            guard let message = spokenHandoffResult ?? handoffFailureMessage else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// The user's own albums holding this memory, as one readable phrase.
    ///
    /// This is the "my album" the whole section exists to answer, and it costs
    /// nothing: `containingAlbums` is already loaded for "Feature Less Often".
    private var ownAlbumNames: String? {
        let names = containingAlbums
            .compactMap { $0.localizedTitle }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return Array(names.prefix(3)).formatted(.list(type: .and))
    }

    private var isWorking: Bool {
        if case .working = handoff { return true }
        return false
    }

    private var handoffResult: String? {
        guard case .done(let outcome) = handoff else { return nil }
        switch outcome {
        case .pinned:
            return "Pinned. In Photos, open Albums → \(PhotosEditHandoff.albumTitle) — it's the only photo in there."
        case .alreadyPinned:
            return "Already pinned. In Photos, open Albums → \(PhotosEditHandoff.albumTitle) — it's the only photo in there."
        }
    }

    /// The same sentence without the arrow, which VoiceOver reads unreliably.
    private var spokenHandoffResult: String? {
        guard case .done(let outcome) = handoff else { return nil }
        let opening = outcome == .alreadyPinned ? "Already pinned." : "Pinned."
        return "\(opening) In Photos, open Albums, then \(PhotosEditHandoff.albumTitle). It is the only photo in there."
    }

    private var handoffFailureMessage: String? {
        guard case .failed(let message) = handoff else { return nil }
        return message
    }

    /// Changes whenever the section's visible state does.
    ///
    /// `isWorking` is not enough on its own: a retry that fails a second time
    /// leaves it false throughout, so neither the animation nor the VoiceOver
    /// announcement fired for the new message.
    private var handoffAnimationKey: String {
        switch handoff {
        case .idle: return "idle"
        case .working: return "working"
        case .done(let outcome): return "done-\(outcome)"
        case .failed(let message): return "failed-\(message)"
        }
    }

    private func stageForEditing() {
        guard !isWorking else { return }
        handoff = .working
        let asset = asset
        Task {
            do {
                let outcome = try await PhotosEditHandoff.stage(asset)
                await MainActor.run { handoff = .done(outcome) }
            } catch {
                await MainActor.run {
                    handoff = .failed(
                        (error as? PhotosEditHandoff.HandoffError)?.errorDescription
                            ?? "That memory couldn't be pinned."
                    )
                }
            }
        }
    }

    private func infoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        MediaDuration.formatted(seconds)
    }
}

/// Carries a memory into the share sheet as one attachment.
///
/// `UIActivityViewController` turns each element of `activityItems` into a
/// separate attachment on the extension item it hands to the receiving app.
/// Passing media plus a caption string therefore produced a two-attachment
/// payload, and an extension written to accept a single movie has to guess
/// which of the two it is meant to post. Snapchat guesses wrong and shows an
/// empty composer.
///
/// So the caption stops being an attachment. `subjectForActivityType` puts it
/// in a mail subject line, and `activityViewControllerLinkMetadata` puts it in
/// the sheet header alongside a poster frame — replacing the raw temporary
/// filename the sheet showed before. Neither is something an extension has to
/// disambiguate.
final class MemoryShareItemSource: NSObject, UIActivityItemSource {
    private let item: Any
    private let caption: String
    private let poster: UIImage?

    init(item: Any, caption: String, poster: UIImage?) {
        self.item = item
        self.caption = caption
        self.poster = poster
    }

    /// The real item, not a stand-in. This is called on the main thread before
    /// the sheet appears, so it has to be something already in hand — it is,
    /// because the export finished before the sheet was presented.
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        item
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        item
    }

    /// Declares the type explicitly rather than letting the sheet infer it from
    /// the path extension, so an extension asking for a specific movie type
    /// gets a definite answer.
    func activityViewController(
        _ controller: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        if let url = item as? URL {
            return UTType(filenameExtension: url.pathExtension)?.identifier
                ?? UTType.movie.identifier
        }
        return UTType.image.identifier
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        caption
    }

    func activityViewControllerLinkMetadata(
        _ controller: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = caption
        if let poster {
            metadata.imageProvider = NSItemProvider(object: poster)
        }
        return metadata
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let source: MemoryShareItemSource
    let cleanupURLs: [URL]

    init(source: MemoryShareItemSource, cleanupURLs: [URL] = []) {
        self.source = source
        self.cleanupURLs = cleanupURLs
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let source: MemoryShareItemSource
    let cleanupURLs: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            // Deleted after a grace period rather than immediately. A share
            // extension can report completion and still be reading the file —
            // some finish the upload in their containing app — and deleting it
            // out from under them fails the send. Anything this misses is
            // caught by the sweep at the start of the next share.
            let urls = cleanupURLs
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        return controller
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
