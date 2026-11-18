import LoupeCore
import SwiftUI

struct LibraryToolbar: ToolbarContent {
    @Bindable var model: AppModel

    /// Grid columns the zoom slider spans; the slider runs the other way (right = fewer, larger photos).
    private static let columnRange = 3...15

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Browse", selection: $model.mode) {
                ForEach(BrowseMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem {
            Slider(value: zoom, in: Double(Self.columnRange.lowerBound)...Double(Self.columnRange.upperBound), step: 1) {
                Text("Zoom")
            } minimumValueLabel: {
                Image(systemName: "minus.magnifyingglass")
            } maximumValueLabel: {
                Image(systemName: "plus.magnifyingglass")
            }
            .labelsHidden()
            .frame(width: 140)
            .help("Zoom")
        }
        ToolbarItem { filterMenu }
        ToolbarItem { sortMenu }
    }

    private var zoom: Binding<Double> {
        let sum = Self.columnRange.lowerBound + Self.columnRange.upperBound
        return Binding(
            get: { Double(sum - model.columns) },
            set: { model.columns = sum - Int($0.rounded()) })
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
