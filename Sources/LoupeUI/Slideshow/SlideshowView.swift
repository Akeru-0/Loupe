import AVFoundation
import AVKit
import AppKit
import LoupeCore
import LoupeIndex
import LoupeMedia
import Observation
import SwiftUI

/// Runs a slideshow (`SlideshowModel`) in a borderless black window that covers the main window's screen, above the
/// menu bar and the Dock. Photos are decoded off the main thread at screen size, only the current and the next one;
/// every result is checked against the current position first, so a late decode never shows a photo stepped past.
/// Ending it (Esc, ✕, the window or the app losing focus, a replaced library) closes the window, stops the timers
/// and the player, removes the event monitor and gives the main window the keyboard back.
@MainActor @Observable final class SlideshowController {
    enum Content {
        case image(CGImage)
        case video(AVPlayer)
        case failed
    }

    /// What is on screen; a new `token` cross-fades.
    struct Slide {
        let token: Int
        let content: Content
    }

    /// A photo as loaded off the main thread: its display version decoded, or the video to play.
    private enum Loaded: Sendable {
        case image(CGImage)
        case video(URL)
        case failed
    }

    private(set) var show: SlideshowModel
    private(set) var slide: Slide?
    private(set) var controlsVisible = true
    /// The pointer is over the control strip, which then stays.
    var isOverControls = false { didSet { if !isOverControls { scheduleHidingControls() } } }

    private unowned let app: AppModel
    private let library: Library
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private weak var previousWindow: NSWindow?
    @ObservationIgnored private var maxPixelSize = 2048
    /// Bumped whenever the current photo changes; older results are dropped.
    @ObservationIgnored private var generation = 0
    /// The generation whose photo is on screen.
    @ObservationIgnored private var shownGeneration = -1
    @ObservationIgnored private var tokens = 0
    /// Loads of the current and the next photo only; a task keeps its decoded image.
    @ObservationIgnored private var loads: [Int64: Task<Loaded, Never>] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var playerObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// The video ended while paused; Play advances.
    @ObservationIgnored private var videoEnded = false
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var hasEnded = false

    init(app: AppModel, library: Library, show: SlideshowModel) {
        self.app = app
        self.library = library
        self.show = show
    }

    // MARK: - Lifetime

    /// Opens the window on `mainWindow`'s screen and shows the first photo.
    func start(over mainWindow: NSWindow?) {
        previousWindow = mainWindow
        guard let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return end(handoff: false) }
        maxPixelSize = max(512, Int((max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor).rounded()))
        let window = SlideshowWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the menu bar and the Dock, just below menus so the interval menu opens over it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // also over a full-screen main window
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(rootView: SlideshowView(controller: self))
        hosting.sizingOptions = []  // the window keeps the screen's size
        window.contentView = hosting
        window.setFrame(screen.frame, display: false)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        startMonitoring(window)
        showCurrent()
        scheduleHidingControls()
    }

    /// Ends the slideshow. With `handoff`, the open viewer or the grid gets the photo it was on.
    func end(handoff: Bool = true) {
        guard !hasEnded else { return }
        hasEnded = true
        generation += 1
        loadTask?.cancel()
        advanceTask?.cancel()
        hideTask?.cancel()
        for task in loads.values { task.cancel() }
        loads = [:]
        stopPlayer()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        slide = nil
        if let window {
            window.orderOut(nil)
            // Closed on the next turn: ✕ ends the slideshow from inside the window's own event handling.
            Task { @MainActor in window.close() }
        }
        window = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        if NSApp.isActive { previousWindow?.makeKeyAndOrderFront(nil) }  // not over the app switched to
        app.slideshowEnded(on: handoff ? show.currentID : nil)
    }

    private func startMonitoring(_ window: NSWindow) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
            let isKey = event.type == .keyDown
            let characters = event.charactersIgnoringModifiers ?? "", modifiers = event.modifierFlags
            let eventWindow = event.window.map(ObjectIdentifier.init)
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Only this window's events; the main window behind keeps its own.
                guard let self, let window = self.window, eventWindow == ObjectIdentifier(window) else { return false }
                guard isKey else {
                    self.pointerMoved()
                    return false
                }
                return self.handleKey(characters: characters, modifiers: modifiers)
            }
            return handled ? nil : event
        }
        // Never left covering the screen behind another window or app.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
        ]
    }

    /// Space plays or pauses, ←/→ step, Esc ends. Every other key is swallowed (the main menu's commands would act
    /// on the hidden grid), except Quit and Hide.
    private func handleKey(characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch KeyCommand.from(characters: characters, modifiers: modifiers) {
        case .toggleViewer?: togglePlay()
        case .closeViewer?: end()
        case .previous?: previous()
        case .next?: next()
        default: return !(modifiers.contains(.command) && ["q", "h"].contains(characters))
        }
        return true
    }

    // MARK: - Playing

    func next() { step { $0.next() } }

    func previous() { step { $0.previous() } }

    func togglePlay() {
        show.togglePlay()
        if !show.isPlaying {
            advanceTask?.cancel()
            player?.pause()
        } else if let player {
            if videoEnded { advance() } else { player.play() }
        } else {
            scheduleAdvance()
        }
    }

    /// The shown photo stays the new interval from now.
    func setInterval(_ seconds: TimeInterval) {
        show.interval = seconds
        scheduleAdvance()
    }

    private func step(_ move: (inout SlideshowModel) -> Void) {
        let before = show.currentID
        move(&show)
        if show.currentID != before { showCurrent() }  // one photo: nothing to redo
    }

    private func advance() {
        let before = show.currentID
        show.tick()
        if show.currentID != before {
            showCurrent()
        } else if let player {  // a slideshow of one video plays it again
            videoEnded = false
            player.seek(to: .zero)
            player.play()
        }
    }

    /// While playing, a still (or a placeholder) stays `interval` seconds once shown; videos advance when they end.
    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard show.isPlaying, show.nextID != nil, shownGeneration == generation, player == nil, !hasEnded else { return }
        let gen = generation, interval = show.interval
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self, !Task.isCancelled, gen == generation else { return }
            advance()
        }
    }

    // MARK: - Loading

    /// Loads the current photo (the previous one stays up meanwhile), then the next one.
    private func showCurrent() {
        generation += 1
        let gen = generation, id = show.currentID
        loadTask?.cancel()
        advanceTask?.cancel()
        stopPlayer()
        let keep = Set([id] + (show.nextID.map { [$0] } ?? []))
        for (other, task) in loads where !keep.contains(other) { task.cancel() }
        loads = loads.filter { keep.contains($0.key) }
        loadTask = Task { [weak self] in
            // While ←/→ is held, photos only stepped past are not decoded.
            if self?.loads[id] == nil { try? await Task.sleep(for: .milliseconds(60)) }
            guard let self, gen == generation, !Task.isCancelled else { return }
            let loaded = await load(id).value
            guard gen == generation, !Task.isCancelled else { return }
            present(loaded)
            if let next = show.nextID { _ = load(next) }
        }
    }

    private func load(_ id: Int64) -> Task<Loaded, Never> {
        if let task = loads[id] { return task }
        let index = library.index, root = library.location.rootURL, size = maxPixelSize
        let task = Task { await Self.read(id, index: index, root: root, maxPixelSize: size) }
        loads[id] = task
        return task
    }

    private func present(_ loaded: Loaded) {
        shownGeneration = generation
        tokens += 1
        switch loaded {
        case .image(let image):
            slide = Slide(token: tokens, content: .image(image))
            scheduleAdvance()
        case .failed:
            slide = Slide(token: tokens, content: .failed)
            scheduleAdvance()
        case .video(let url):
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            observe(item)
            slide = Slide(token: tokens, content: .video(player))
            if show.isPlaying { player.play() }
        }
    }

    // MARK: - Video

    private func observe(_ item: AVPlayerItem) {
        let gen = generation
        let center = NotificationCenter.default
        playerObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.videoFinished(generation: gen, failed: false) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.videoFinished(generation: gen, failed: true) }
            },
        ]
        // An unreadable file never plays to its end.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.videoFinished(generation: gen, failed: true) } }
        }
    }

    private func videoFinished(generation gen: Int, failed: Bool) {
        guard gen == generation, player != nil else { return }
        if failed {
            stopPlayer()
            tokens += 1
            slide = Slide(token: tokens, content: .failed)
            scheduleAdvance()
        } else if show.isPlaying {
            advance()
        } else {
            videoEnded = true
        }
    }

    private func stopPlayer() {
        for observer in playerObservers { NotificationCenter.default.removeObserver(observer) }
        playerObservers = []
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoEnded = false
    }

    // MARK: - Control strip

    /// The strip shows while the pointer moves and hides 2 s after it stops, with the pointer.
    func pointerMoved() {
        if !controlsVisible { controlsVisible = true }
        scheduleHidingControls()
    }

    private func scheduleHidingControls() {
        hideTask?.cancel()
        guard !hasEnded else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !isOverControls else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: - Off the main thread

    @concurrent nonisolated private static func read(
        _ id: Int64, index: LibraryIndex, root: URL, maxPixelSize: Int
    ) async -> Loaded {
        guard !Task.isCancelled, let photo = try? index.photo(id: id), let versions = try? index.versions(ofPhoto: id),
            let display = versions.first(where: \.isDisplay) ?? versions.first
        else { return .failed }
        let url = display.url(in: root)
        if display.kind == .video || display.kind == .live { return .video(url) }
        guard !Task.isCancelled else { return .failed }
        return ImageLoader.image(at: url, maxPixelSize: maxPixelSize, rotation: photo.rotation).map(Loaded.image) ?? .failed
    }
}

/// Borderless windows can't become key by default; the slideshow needs the keyboard.
private final class SlideshowWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The slideshow window's content: the current slide on black, cross-fading over 0.5 s, and the control strip.
struct SlideshowView: View {
    var controller: SlideshowController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let slide = controller.slide {
                SlideView(content: slide.content)
                    .id(slide.token)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: controller.slide?.token)
        .overlay(alignment: .bottom) {
            if controller.controlsVisible {
                SlideshowControls(controller: controller)
                    .padding(.bottom, 48)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.controlsVisible)
        .environment(\.colorScheme, .dark)
    }
}

private struct SlideView: View {
    let content: SlideshowController.Content

    var body: some View {
        switch content {
        case .image(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .video(let player):
            SlideshowVideoView(player: player)
        case .failed:
            ContentUnavailableView("Can't Display This File", systemImage: "exclamationmark.triangle")
        }
    }
}

/// ◀ ⏯ ▶, the interval menu and ✕.
private struct SlideshowControls: View {
    var controller: SlideshowController

    var body: some View {
        let show = controller.show
        HStack(spacing: 22) {
            Group {
                Button { controller.previous() } label: { Image(systemName: "backward.fill") }
                    .help("Previous (←)")
                Button { controller.togglePlay() } label: {
                    Image(systemName: show.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .help(show.isPlaying ? "Pause (Space)" : "Play (Space)")
                Button { controller.next() } label: { Image(systemName: "forward.fill") }
                    .help("Next (→)")
            }
            .disabled(show.photoIDs.count < 2)
            Menu {
                Picker("Interval", selection: Binding(get: { show.interval }, set: { controller.setInterval($0) })) {
                    ForEach(SlideshowModel.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text("\(Int(show.interval)) s").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Interval")
            Button { controller.end() } label: { Image(systemName: "xmark") }
                .help("End Slideshow (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 17, weight: .medium))
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .onHover { controller.isOverControls = $0 }
    }
}

/// A slideshow video without controls. The player is owned (paused and released) by `SlideshowController`.
private struct SlideshowVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
