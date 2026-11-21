import AppKit
import LocalAuthentication
import LoupeCore
import SwiftUI

/// Hidden and Recently Deleted are locked: they show their photos only after Touch ID or the Mac's password, asked
/// for as soon as one is opened. One unlock covers both for 15 minutes (`unlockDuration`): they lock again then, or
/// sooner when the screen locks or the Mac sleeps, or with the padlock next to them in the sidebar.
extension AppModel {
    /// The current view is one that locks.
    var isLockedScope: Bool { query.scope == .hidden || query.scope == .recentlyDeleted }
    /// The current view locks and hasn't been unlocked.
    var isLocked: Bool { isLockedScope && !isUnlocked }

    /// Asks for Touch ID (or the Mac's password) and unlocks.
    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error { present(error) }
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show “\(selectedTitle)”")
            isUnlocked = true
            unlockDeclined = false
        } catch {
            unlockDeclined = true  // cancelled or failed: the button asks again
        }
    }

    /// Asks by itself when a locked view is opened or Loupe comes back to the front, not while another app is
    /// active and not again right after the prompt was cancelled.
    func unlockIfAsked() async {
        guard isLocked, NSApp.isActive, !unlockDeclined, !isAuthenticating else { return }
        await unlock()
    }

    /// Locks again; a viewer open on a locked view's photo closes. `byHand`: the padlock was clicked, so the view
    /// shown doesn't ask again right away.
    func lock(byHand: Bool = false) {
        guard isUnlocked else { return }
        isUnlocked = false
        unlockDeclined = byHand
        if isLockedScope { viewerPhotoID = nil }
    }

    /// Starts the relock timer on unlock; cancels it on lock.
    func unlockChanged() {
        relockTask?.cancel()
        relockTask = nil
        guard isUnlocked else {
            unlockExpiry = nil
            return
        }
        let duration = unlockDuration
        unlockExpiry = Date().addingTimeInterval(Double(duration.components.seconds))
        relockTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    /// Called once at launch: the screen locking (or the Mac sleeping, or another user taking over) locks.
    func lockWhenScreenLocks() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }
}

/// Shown instead of the photos of a locked view.
struct LockedView: View {
    var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("\(model.selectedTitle) Is Locked", systemImage: "lock.fill")
        } description: {
            Text("Use Touch ID or your password to view these photos.")
        } actions: {
            Button("View Photos") { Task { await model.unlock() } }
                .keyboardShortcut(.defaultAction)
        }
        .task(id: model.selectedItemID) { await model.unlockIfAsked() }  // as soon as it is opened
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.unlockIfAsked() }
        }
    }
}
