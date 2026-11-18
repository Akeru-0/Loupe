import LoupeCore
import SwiftUI

@main
struct LoupeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Loupe \(LoupeCore.version)")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
