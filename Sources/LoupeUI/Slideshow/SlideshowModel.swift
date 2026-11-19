import Foundation

/// The slideshow's order and position: which photos play, which one is shown, whether it plays and how long each
/// photo stays. Pure; `SlideshowController` runs the timer, the decoding and the window.
struct SlideshowModel: Equatable {
    /// The choices of the control strip's interval menu, in seconds.
    static let intervals: [TimeInterval] = [2, 3, 5, 10]

    let photoIDs: [Int64]
    private(set) var index: Int
    var interval: TimeInterval = 3
    private(set) var isPlaying = true

    /// The targets (`AppModel.actionTargetIDs`, in query order) if there are two or more; otherwise the whole query
    /// (`order`), starting at the selected or viewed photo when the query has it. Nil when there is nothing to show.
    init?(targets: [Int64], order: [Int64]) {
        if targets.count >= 2 {
            photoIDs = targets
            index = 0
        } else if !order.isEmpty {
            photoIDs = order
            index = targets.first.flatMap(order.firstIndex(of:)) ?? 0
        } else if let only = targets.first {
            photoIDs = [only]  // the viewer's photo, which has left an otherwise empty query
            index = 0
        } else {
            return nil
        }
    }

    var currentID: Int64 { photoIDs[index] }

    /// The photo `next()` and `tick()` go to; nil when that is the current one (a slideshow of one photo).
    var nextID: Int64? { photoIDs.count > 1 ? photoIDs[(index + 1) % photoIDs.count] : nil }

    /// Steps forward, wrapping to the start after the last photo.
    mutating func next() { index = (index + 1) % photoIDs.count }

    /// Steps back, wrapping to the end before the first photo.
    mutating func previous() { index = (index + photoIDs.count - 1) % photoIDs.count }

    mutating func togglePlay() { isPlaying.toggle() }

    /// The interval ran out (or a video ended): advances while playing, does nothing while paused.
    mutating func tick() {
        if isPlaying { next() }
    }
}
