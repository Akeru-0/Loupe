/// A built-in feature that plugs extension points into the app.
public protocol LoupeFeature: Sendable {
    static func register(in registry: inout FeatureRegistry)
}
