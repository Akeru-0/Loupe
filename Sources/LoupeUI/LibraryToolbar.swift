import LoupeCore
import SwiftUI

struct LibraryToolbar: ToolbarContent {
    @Bindable var model: AppModel
    var width: Width

    /// How much room the toolbar's trailing items have (left of them: the title, or the viewer's centred heading);
    /// they collapse in steps as the window narrows.
    enum Width {
        /// The action buttons collapse into a menu, the zoom slider into − / + buttons.
        case narrow
        /// The zoom slider collapses into − / + buttons.
        case medium
        case wide

        /// `room`: points left for the trailing items, up to the detail column's right edge. The thresholds are what
        /// the items take: actions (~190) or their menu (~40), slider (~220) or buttons (~60), filter and sort
        /// (~80), with the gaps between them and the window edge.
        init(room: CGFloat) {
            self = room >= 560 ? .wide : room >= 400 ? .medium : .narrow
        }

        /// What the fully collapsed toolbar takes; with less, the viewer's heading has to move aside.
        static let minimumRoom: CGFloat = 256
    }

    /// The zoom steps the slider spans (`GridLayout.zoomLevels`); it runs the other way (right = fewer, larger photos).
    private static let levels = GridLayout.zoomLevels

    var body: some ToolbarContent {
        if model.canGoBack {
            ToolbarItem(placement: .navigation) {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help(model.viewerPhotoID != nil ? "Back to the grid" : "Back")
            }
        }
        ToolbarItem { ActionCapsule(model: model, isCollapsed: width == .narrow) }
        // Its own capsule: macOS 26 merges adjacent toolbar items into one.
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            if width == .wide { zoomSlider } else { zoomButtons }
        }
        ToolbarItem { filterMenu }
        ToolbarItem { sortMenu }
    }

    private var zoomSlider: some View {
        Slider(value: zoom, in: 0...Double(Self.levels.count - 1), step: 1) {
            Text("Zoom")
        } minimumValueLabel: {
            Image(systemName: "minus.magnifyingglass")
        } maximumValueLabel: {
            Image(systemName: "plus.magnifyingglass")
        }
        .labelsHidden()
        .frame(width: 200)
        .padding(.horizontal, 8)  // room inside the toolbar's capsule around the magnifier icons
        .help("Zoom")
    }

    private var zoomButtons: some View {
        HStack(spacing: 12) {
            Button { model.columns = GridLayout.zoomed(model.columns, by: 1) } label: { zoomSymbol("minus.magnifyingglass") }
                .help("Zoom Out")
                .disabled(model.columns >= Self.levels.last!)
            Button { model.columns = GridLayout.zoomed(model.columns, by: -1) } label: { zoomSymbol("plus.magnifyingglass") }
                .help("Zoom In")
                .disabled(model.columns <= Self.levels.first!)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)  // room inside the toolbar's capsule, as in the action capsule
    }

    private func zoomSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
    }

    private var zoom: Binding<Double> {
        let last = Self.levels.count - 1
        return Binding(
            get: { Double(last - (Self.levels.firstIndex { $0 >= model.columns } ?? last)) },
            set: { model.columns = Self.levels[max(0, min(last, last - Int($0.rounded())))] })
    }

    private var isFiltering: Bool {
        model.query.minRating > 0 || model.query.kind != .any || model.query.camera != nil || model.query.lens != nil
    }

    private var filterMenu: some View {
        Menu {
            Picker("Rating", selection: $model.query.minRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { n in
                    Text(n == 5 ? "★★★★★" : String(repeating: "★", count: n) + " or More").tag(n)
                }
            }
            Picker("Kind", selection: $model.query.kind) {
                Text("Any Kind").tag(PhotoQuery.KindFilter.any)
                Text("Has RAW").tag(PhotoQuery.KindFilter.hasRaw)
                Text("Without RAW").tag(PhotoQuery.KindFilter.withoutRaw)
                Text("Videos").tag(PhotoQuery.KindFilter.videos)
                Text("Edited in LightCraft").tag(PhotoQuery.KindFilter.lightCraftEdited)
            }
            Picker("Camera", selection: $model.query.camera) {
                Text("Any Camera").tag(String?.none)
                ForEach(model.cameras, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Lens", selection: $model.query.lens) {
                Text("Any Lens").tag(String?.none)
                ForEach(model.lenses, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            Label(
                "Filter",
                systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.query.sort) {
                Text("Capture Date").tag(PhotoQuery.SortField.captureDate)
                Text("Date Added").tag(PhotoQuery.SortField.added)
                Text("Name").tag(PhotoQuery.SortField.name)
                Text("Rating").tag(PhotoQuery.SortField.rating)
                if case .recentlyEdited = model.query.scope {
                    Text("Date Edited").tag(PhotoQuery.SortField.edited)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $model.query.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort")
    }
}


/// The toolbar subtitle under the title: "251 Photos · June – September 2026", the months being those of the photos
/// on screen.
func photosSubtitle(count: Int, months: ClosedRange<Date>?) -> String {
    guard count > 0 else { return "" }
    var parts = [count == 1 ? "1 Photo" : "\(count.formatted()) Photos"]
    if let months {
        let monthYear = Date.FormatStyle().month(.wide).year()
        let (first, last) = (months.lowerBound, months.upperBound)
        if first == last {
            parts.append(first.formatted(monthYear))
        } else if Calendar.current.isDate(first, equalTo: last, toGranularity: .year) {
            parts.append("\(first.formatted(.dateTime.month(.wide))) – \(last.formatted(monthYear))")
        } else {
            parts.append("\(first.formatted(monthYear)) – \(last.formatted(monthYear))")
        }
    }
    return parts.joined(separator: " · ")
}

/// The title bar's centre while the viewer is open: the photo's date and its place in the list. Placed by
/// `TitlebarCenterAccessory` so it is centred in the window whatever the sidebar width.
struct TitlebarCenter: View {
    var model: AppModel

    /// Half the heading's width plus a gap; the toolbar's trailing items keep right of it.
    static let maxHalfWidth: CGFloat = 124
    /// The heading's left edge stays right of this, clear of the traffic lights and the sidebar button.
    static let minLeading: CGFloat = 124

    var body: some View {
        if model.viewerPhotoID != nil { ViewerHeading(model: model) }
    }
}

/// "November 14, 2026 at 1:03:53 PM" over "241 of 251", as Photos titles its viewer.
private struct ViewerHeading: View {
    var model: AppModel

    var body: some View {
        let photo = model.viewerPhoto.flatMap { $0.id == model.viewerPhotoID ? $0 : nil }
        VStack(spacing: 1) {
            Text(photo.map { $0.captureDate?.formatted(date: .long, time: .standard) ?? $0.stem } ?? " ")
                .font(.system(size: 13, weight: .semibold))
            if let position = model.viewerPosition {
                Text("\(position.formatted()) of \(model.photoCount.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}
