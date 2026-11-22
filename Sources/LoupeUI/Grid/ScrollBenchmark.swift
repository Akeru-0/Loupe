#if DEBUG || LOUPE_BENCH
import AppKit
import QuartzCore

/// Development only: measures how smoothly the grid scrolls. Launched with
/// `-LoupeScrollBenchmark <results file> [-LoupeBenchColumns N] [-LoupeBenchSpeed points/s]`, it waits for the
/// library's scan, scrolls the whole grid top to bottom twice (cold: previews being made; warm: from the cache) at
/// a steady speed, appends one line of results per pass to the file, and quits.
@MainActor final class ScrollBenchmark: NSObject {
    private weak var scrollView: NSScrollView?
    private let output: URL
    private let speed: CGFloat
    private let emptyTiles: () -> (empty: Int, shown: Int)
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var intervals: [Double] = []
    private var emptyFraction: [Double] = []
    private var pass = 0
    private var done: () -> Void

    static var requested: (output: URL, columns: Int?, speed: CGFloat)? {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: "LoupeScrollBenchmark") else { return nil }
        let columns = d.integer(forKey: "LoupeBenchColumns")
        let speed = d.double(forKey: "LoupeBenchSpeed")
        return (URL(fileURLWithPath: path), columns > 0 ? columns : nil, speed > 0 ? speed : 6000)
    }

    init(scrollView: NSScrollView, output: URL, speed: CGFloat,
         emptyTiles: @escaping () -> (empty: Int, shown: Int), done: @escaping () -> Void) {
        self.scrollView = scrollView
        self.output = output
        self.speed = speed
        self.emptyTiles = emptyTiles
        self.done = done
    }

    func start() {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        intervals = []
        emptyFraction = []
        last = nil
        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, let document = scrollView.documentView else { return finish() }
        let now = link.timestamp
        if let last { intervals.append(now - last) }
        let step = last.map { CGFloat(now - $0) * speed } ?? 0
        last = now
        let clip = scrollView.contentView
        let maxY = document.frame.height - clip.bounds.height
        let y = min(maxY, clip.bounds.minY + step)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        let tiles = emptyTiles()
        if tiles.shown > 0 { emptyFraction.append(Double(tiles.empty) / Double(tiles.shown)) }
        if y >= maxY { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let frame = (NSScreen.main?.minimumRefreshInterval ?? 1.0 / 60)
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
        let sorted = intervals.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let empty = emptyFraction.isEmpty ? 0 : emptyFraction.reduce(0, +) / Double(emptyFraction.count)
        let line = String(
            format: "%@ pass: %d frames, %d dropped (%.1f%%), p99 %.1f ms, worst %.1f ms, empty tiles %.1f%%\n",
            pass == 0 ? "cold" : "warm", intervals.count, dropped,
            100 * Double(dropped) / Double(max(1, intervals.count + dropped)), p99 * 1000, (sorted.last ?? 0) * 1000,
            empty * 100)
        if let handle = try? FileHandle(forWritingTo: output) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: output)
        }
        pass += 1
        if pass < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        } else {
            done()
        }
    }
}
#endif
