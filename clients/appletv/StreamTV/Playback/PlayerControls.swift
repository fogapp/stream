import SwiftUI
import UIKit

/// Where focus is in the player: the picture itself (the transport — what
/// the remote's clicks and swipes drive), the row of buttons under the
/// timeline, or one of the things that asks for a press.
enum PlayerFocus: Hashable {
    case surface
    case play, back, forward, subtitles, audio, speed, related
    case skip, alwaysSkip, sponsor, undo
    case upNextPlay, upNextDismiss
    case close
    /// The nth choice in the open sheet.
    case option(Int)
}

/// The player's side sheets (the web's menus above the controls).
enum PlayerPanel: Hashable {
    case subtitles, audio, speed, related
}

// MARK: - The timeline

/// The web's SeekBar, for a room: played in cyan over what's buffered,
/// chapter gaps and SponsorBlock spans on the track, and — while someone
/// scrubs — a head of its own with the moment's thumbnail, time and chapter.
struct SeekBar: View {
    let model: PlayerModel
    @State private var thumbnail: UIImage?

    private static let preview = CGSize(width: 384, height: 216)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                track(width)
                Circle().fill(Palette.primary)
                    .frame(width: 28, height: 28)
                    .shadow(color: Palette.scrim.opacity(0.5), radius: 6)
                    .offset(x: x(model.current, width) - 14)
                if let scrub = model.scrubTime {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.foreground)
                        .frame(width: 6, height: 44)
                        .offset(x: x(scrub, width) - 3)
                    scrubPreview(scrub)
                        .position(x: min(max(x(scrub, width), Self.preview.width / 2), width - Self.preview.width / 2),
                                  y: model.session.trickplay == nil ? -34 : -Self.preview.height / 2 - 70)
                }
            }
            .frame(height: 44)
        }
        .frame(height: 44)
        .task(id: thumbnailKey) {
            guard let scrub = model.scrubTime else { return }
            thumbnail = await model.thumbnail(at: scrub)
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Clock.format(model.current)) of \(Clock.format(model.duration))")
    }

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / model.duration, 0), 1)) * width
    }

    private var thumbnailKey: Int? {
        guard let scrub = model.scrubTime, let trickplay = model.session.trickplay else { return nil }
        return Int(scrub / trickplay.interval)
    }

    private func track(_ width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Palette.foreground.opacity(0.25))
            Rectangle().fill(Palette.foreground.opacity(0.4)).frame(width: x(model.buffered, width))
            Rectangle().fill(Palette.primary).frame(width: x(model.current, width))
            ForEach(Array((model.session.segments ?? []).enumerated()), id: \.offset) { _, segment in
                Rectangle().fill(segment.category == "sponsor" ? Palette.positive : Palette.warning)
                    .frame(width: max(x(segment.end, width) - x(segment.start, width), 3))
                    .offset(x: x(segment.start, width))
            }
            ForEach(Array((model.session.chapters ?? []).dropFirst().enumerated()), id: \.offset) { _, chapter in
                Rectangle().fill(Palette.background).frame(width: 4).offset(x: x(chapter.start, width) - 2)
            }
        }
        .frame(width: width, height: 10)
        .clipShape(Capsule())
    }

    private func scrubPreview(_ seconds: Double) -> some View {
        VStack(spacing: 12) {
            if model.session.trickplay != nil {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Palette.surface
                    }
                }
                .frame(width: Self.preview.width, height: Self.preview.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.foreground.opacity(0.85), lineWidth: 3))
                .shadow(color: Palette.scrim.opacity(0.6), radius: 20, y: 8)
            }
            HStack(spacing: 10) {
                Text(Clock.format(seconds)).font(TextStyle.callout.font.monospacedDigit().weight(.semibold))
                if let title = model.chapter(at: seconds)?.title {
                    Text("· \(title)").font(TextStyle.callout.font).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Palette.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 520)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The bars

/// Title and subtitle over a gradient; the time of day and when it ends.
struct PlayerTopBar: View {
    let model: PlayerModel

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.session.title ?? "").textStyle(.title2).lineLimit(1)
                if let subtitle = model.session.subtitle { Text(subtitle).textStyle(.callout, color: Palette.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { context in
                VStack(alignment: .trailing, spacing: 8) {
                    Text(context.date.formatted(date: .omitted, time: .shortened)).font(TextStyle.title2.font.monospacedDigit())
                        .foregroundStyle(Palette.foreground)
                    if let ends = endsAt(from: context.date) {
                        Text("Ends at \(ends.formatted(date: .omitted, time: .shortened))").textStyle(.callout, color: Palette.muted)
                    }
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 60)
        .padding(.bottom, 120)
        .background(LinearGradient(colors: [Palette.scrim.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
    }

    private func endsAt(from now: Date) -> Date? {
        guard model.duration > 0 else { return nil }
        return now.addingTimeInterval((model.duration - model.current) / Double(max(model.rate, 0.1)))
    }
}

/// The timeline, the clock, and the web's control row.
struct PlayerBottomBar: View {
    let model: PlayerModel
    let hasRelated: Bool
    let focus: FocusState<PlayerFocus?>.Binding
    let open: (PlayerPanel) -> Void
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SeekBar(model: model)
            HStack(spacing: 14) {
                Text("\(Clock.format(model.current)) / \(Clock.format(model.duration))")
                    .font(TextStyle.callout.font.monospacedDigit()).foregroundStyle(Palette.foreground.opacity(0.85))
                if let title = model.chapter(at: model.current)?.title {
                    Text("· \(title)").textStyle(.callout, color: Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.rate != 1 { Badge(text: speedLabel(model.rate), tone: .info) }
            }
            HStack(spacing: 18) {
                ControlButton(label: model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill") { model.togglePlay() }
                    .focused(focus, equals: .play)
                ControlButton(label: "Back 10 seconds", systemImage: "gobackward.10") { model.jump(by: -10) }
                    .focused(focus, equals: .back)
                ControlButton(label: "Forward 10 seconds", systemImage: "goforward.10") { model.jump(by: 10) }
                    .focused(focus, equals: .forward)
                Spacer(minLength: 0)
                if !model.textTracks.isEmpty || !model.pictureTracks.isEmpty {
                    ControlButton(label: "Subtitles", systemImage: model.subtitle != nil || model.session.burnedSubtitle != nil ? "captions.bubble.fill" : "captions.bubble") { open(.subtitles) }
                        .focused(focus, equals: .subtitles)
                }
                if (model.session.mediaFile?.audio.count ?? 0) > 1 {
                    ControlButton(label: "Audio", systemImage: "waveform") { open(.audio) }
                        .focused(focus, equals: .audio)
                }
                ControlButton(label: "Speed", systemImage: "gauge.with.dots.needle.67percent") { open(.speed) }
                    .focused(focus, equals: .speed)
                if hasRelated {
                    ControlButton(label: "Related", systemImage: "list.bullet.rectangle") { open(.related) }
                        .focused(focus, equals: .related)
                }
            }
            .focusSection()
            // Up from the row goes back to the picture.
            .onMoveCommand { if $0 == .up { back() } }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 140)
        .padding(.bottom, 56)
        .background(LinearGradient(colors: [.clear, Palette.scrim.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }
}

func speedLabel(_ rate: Float) -> String {
    rate == 1 ? "Normal" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
}

/// A round control: its name slides out beside it while focused.
struct ControlButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { focused in
                HStack(spacing: 14) {
                    Image(systemName: systemImage).font(.system(size: 30, weight: .semibold)).frame(width: 40)
                    if focused { Text(label).font(TextStyle.callout.font.weight(.semibold)).lineLimit(1).fixedSize() }
                }
                .foregroundStyle(focused ? Palette.primaryForeground : Palette.foreground)
                .padding(.horizontal, focused ? 26 : 18)
                .frame(height: 76)
                .background(focused ? Palette.primaryHover : Palette.foreground.opacity(0.14), in: Capsule())
                .focusGrow(focused, 1.06)
                .focusMotion(focused)
            }
        }
        .buttonStyle(.streamCard)
        .accessibilityLabel(label)
    }
}

// MARK: - Side sheets

/// A panel down the right: the web's menus above the controls, as a TV
/// lists things.
struct PlayerSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).textStyle(.title2)
                .padding(.horizontal, 48)
                .padding(.top, 70)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .frame(width: 680)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            Palette.surface.opacity(0.97)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1.5) }
                .shadow(color: Palette.scrim.opacity(0.6), radius: 40, x: -20)
                .ignoresSafeArea()
        )
        .focusSection()
    }
}

/// One choice in a sheet, ticked when it's the one in use.
struct SheetOption: View {
    let label: String
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { focused in
                HStack(spacing: 20) {
                    Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).opacity(selected ? 1 : 0).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(TextStyle.headline.font).lineLimit(1)
                        if let detail { Text(detail).font(TextStyle.caption.font).opacity(0.75).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(focused ? Palette.primaryForeground : selected ? Palette.primary : Palette.foreground)
                .padding(.horizontal, 20)
                .frame(minHeight: 76)
                .background(focused ? Palette.primaryHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .focusGrow(focused, 1.02)
            }
        }
        .buttonStyle(.streamCard)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Something related, in the Related sheet: the one playing marked.
struct RelatedRow: View {
    let card: Card
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { focused in
                HStack(alignment: .top, spacing: 22) {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(artwork: card.wideImage, width: 224, fallback: card.heading)
                        if let progress = card.progress, progress > 0 { ProgressBar(value: progress, height: 5) }
                    }
                    .frame(width: 224, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(playing ? Palette.primary : Palette.border, lineWidth: playing ? 3 : 1.5))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.kind == "episode" ? (card.title ?? card.code ?? "") : card.heading)
                            .font(TextStyle.callout.font.weight(.semibold)).lineLimit(2)
                        if let detail = card.kind == "episode" ? card.code : card.detail, !detail.isEmpty {
                            Text(detail).font(TextStyle.caption.font).opacity(0.75).lineLimit(1)
                        }
                        if playing {
                            Label("Playing", systemImage: "speaker.wave.2.fill").font(TextStyle.caption.font.weight(.semibold))
                                .foregroundStyle(focused ? Palette.primaryForeground : Palette.primary)
                        } else if card.watched == true {
                            Label("Watched", systemImage: "checkmark").font(TextStyle.caption.font).opacity(0.75)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(focused ? Palette.primaryForeground : Palette.foreground)
                .padding(14)
                .background(focused ? Palette.primaryHover : playing ? Palette.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .focusGrow(focused, 1.02)
            }
        }
        .buttonStyle(.streamCard)
    }
}

// MARK: - What asks for a press

/// Up next (the web's card): the next one with a countdown to it, and a
/// way out; after a run with nobody touching anything, it asks instead.
struct UpNextCard: View {
    let next: PlaybackSession.NextUp
    let left: Int
    let stillWatching: Bool
    let focus: FocusState<PlayerFocus?>.Binding
    let play: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkImage(artwork: next.image, width: 540, fallback: next.label)
                .frame(width: 540, height: 304)
                .clipped()
            VStack(alignment: .leading, spacing: 14) {
                Text(stillWatching ? "Still watching?" : "Up next in \(left)").textStyle(.eyebrow, color: Palette.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: left)
                Text(next.label.isEmpty ? (next.title ?? "Next") : next.label).textStyle(.headline).lineLimit(2)
                if next.playlistId != nil, let show = next.showTitle { Text(show).textStyle(.caption, color: Palette.muted).lineLimit(1) }
                HStack(spacing: 16) {
                    Button(action: play) { Label(stillWatching ? "Keep watching" : "Play now", systemImage: "play.fill") }
                        .buttonStyle(.stream(.primary, compact: true))
                        .focused(focus, equals: .upNextPlay)
                    Button(stillWatching ? "I'm done" : "Watch credits", action: dismiss)
                        .buttonStyle(.stream(.ghost, compact: true))
                        .focused(focus, equals: .upNextDismiss)
                }
                .padding(.top, 6)
            }
            .padding(28)
        }
        .frame(width: 540, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
        .shadow(color: Palette.scrim.opacity(0.6), radius: 30, y: 12)
        .focusSection()
    }
}

// MARK: - The touch surface

/// Swipes on the Siri Remote's touch surface, for scrubbing: a pan on the
/// window (the remote's touches reach every view up the chain), on only
/// while the picture has focus, so menus still move by swipes.
struct TouchSurface: UIViewRepresentable {
    var enabled: Bool
    var began: () -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isUserInteractionEnabled = false
        host.coordinator = context.coordinator
        context.coordinator.surface = self
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        context.coordinator.surface = self
        context.coordinator.recognizer.isEnabled = enabled
    }

    static func dismantleUIView(_ host: Host, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: TouchSurface?
        lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                surface?.began()
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                surface?.moved(translation.x)
            case .ended, .cancelled, .failed:
                surface?.ended()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    final class Host: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let recognizer = coordinator?.recognizer, recognizer.view !== window else { return }
            window.addGestureRecognizer(recognizer)
        }
    }
}
