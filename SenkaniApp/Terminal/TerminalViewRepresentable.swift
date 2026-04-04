import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView for use in SwiftUI.
///
/// Design: The terminal NSView is used DIRECTLY — no wrapper, no gesture
/// interceptors, no overlays that eat events. SwiftUI must not interfere
/// with the NSView's event handling or the terminal won't accept input.
struct TerminalViewRepresentable: NSViewRepresentable {
    let shellPath: String
    let environment: [String: String]
    let workingDirectory: String
    let isActive: Bool
    let onProcessExited: ((Int32) -> Void)?
    let onActivate: (() -> Void)?

    init(shellPath: String = "/bin/zsh",
         environment: [String: String] = [:],
         workingDirectory: String = NSHomeDirectory(),
         isActive: Bool = true,
         onProcessExited: ((Int32) -> Void)? = nil,
         onActivate: (() -> Void)? = nil) {
        self.shellPath = shellPath
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.isActive = isActive
        self.onProcessExited = onProcessExited
        self.onActivate = onActivate
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.processDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white

        // Build environment: inherit current + add our overrides
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Start the shell process
        tv.startProcess(
            executable: shellPath,
            args: [],
            environment: envPairs,
            execName: (shellPath as NSString).lastPathComponent,
            currentDirectory: workingDirectory
        )

        // Monitor when ANY click happens inside the terminal to activate
        // the parent pane. This uses an NSEvent local monitor so we don't
        // interfere with the terminal's own event handling at all.
        let activate = onActivate
        context.coordinator.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Check if the click landed inside our terminal view
            if let eventWindow = event.window,
               eventWindow == tv.window {
                let locationInTV = tv.convert(event.locationInWindow, from: nil)
                if tv.bounds.contains(locationInTV) {
                    activate?()
                }
            }
            // Always pass the event through — never consume it
            return event
        }

        // Request focus after the view is in the window hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            tv.window?.makeFirstResponder(tv)
        }

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // When this pane becomes active, ensure the terminal has focus
        if isActive {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder !== nsView {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // Clean up the event monitor
        if let monitor = coordinator.mouseMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.mouseMonitor = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExited: onProcessExited)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExited: ((Int32) -> Void)?
        var mouseMonitor: Any?

        init(onProcessExited: ((Int32) -> Void)?) {
            self.onProcessExited = onProcessExited
        }

        deinit {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessExited?(exitCode ?? -1)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
