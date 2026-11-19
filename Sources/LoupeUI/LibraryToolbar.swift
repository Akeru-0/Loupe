import LoupeCore
import SwiftUI

struct LibraryToolbar: ToolbarContent {
    @Bindable var model: AppModel

    /// Grid columns the zoom slider spans; the slider runs the other way (right = fewer, larger photos).
    private static let columnRange = GridLayout.columnRange

    var body: some ToolbarContent {
        ToolbarItem { ActionCapsule(model: model) }
        // Its own capsule: macOS 26 merges adjacent toolbar items into one.
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            Slider(value: zoom, in: Double(Self.columnRange.lowerBound)...Double(Self.columnRange.upperBound), step: 1) {
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


/// Years / Months / Days / All Photos. Shown centred in the window's title bar (see `TitlebarCenterAccessory`),
/// not in the detail column's toolbar, so it sits in the middle of the window — under the notch when the
/// window spans the screen — whatever the sidebar width. Drawn by hand in the toolbar's glass-capsule style,
/// because outside the toolbar a system segmented control falls back to the classic blue look.
struct BrowseModePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BrowseMode.allCases, id: \.self) { mode in
                let selected = model.mode == mode
                Button {
                    model.mode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background { if selected { Capsule().fill(.primary.opacity(0.14)) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .modifier(GlassCapsule())
        .fixedSize()
    }
}

/// Liquid Glass capsule on macOS 26+, a material capsule before that.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
