import AppKit

/// A pinned date header ("Monday, 3 June 2024", "June 2024", "2024") on a material background.
final class SectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")

    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        addSubview(background)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        background.frame = bounds
        label.sizeToFit()
        label.frame = CGRect(
            x: 12, y: (bounds.height - label.frame.height) / 2,
            width: max(0, bounds.width - 24), height: label.frame.height)
    }
}
