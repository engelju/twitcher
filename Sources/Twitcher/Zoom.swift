import SwiftUI

/// UI zoom factor (1.0 = default). Views scale their fonts and key
/// dimensions by this. The video player is intentionally left alone —
/// it always fills its area at native resolution.
private struct UIZoomKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var uiZoom: Double {
        get { self[UIZoomKey.self] }
        set { self[UIZoomKey.self] = newValue }
    }
}
