import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Clipboard hotkey actions that require access outside the sandbox.
enum ClipboardHelperHandler: HelperHandler {
    private static let finderBundleID = "com.apple.finder"
    private static let terminalBundleID = "com.apple.Terminal"

    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping":
            reply(["ok": true])
        case "pasteKey":
            reply(postPasteKey())
        case "copyPath", "newFile", "openTerminal":
            DispatchQueue.global(qos: .userInitiated).async {
                reply(runFinderAction(action, args: args))
            }
        default:
            reply(HelperRouter.unknown(action))
        }
    }

    private static func postPasteKey() -> HelperArgs {
        guard AXIsProcessTrusted() else {
            return ["ok": false, "permissionRequired": "accessibility", "error": "Accessibility access is required to paste."]
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return ["ok": false, "error": "Could not create the paste event."]
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return ["ok": true]
    }

    private static func runFinderAction(_ action: String, args: HelperArgs) -> HelperArgs {
        let targets = action == "openTerminal" ? [finderBundleID, terminalBundleID] : [finderBundleID]
        guard targets.allSatisfy(hasAutomationAccess) else {
            return ["ok": false, "permissionRequired": "automation", "error": "Automation access is required for Finder tools."]
        }

        switch action {
        case "copyPath":
            guard let result = execute("""
                tell application "Finder"
                    set selectedItems to selection
                    set pathList to {}
                    repeat with selectedItem in selectedItems
                        try
                            set end of pathList to POSIX path of (selectedItem as alias)
                        end try
                    end repeat
                end tell
                set AppleScript's text item delimiters to linefeed
                set pathText to pathList as text
                set AppleScript's text item delimiters to ""
                return pathText
                """),
                  let paths = result.stringValue,
                  !paths.isEmpty else {
                return ["ok": false, "error": "Finder has no selected items to copy."]
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(paths, forType: .string) else {
                return ["ok": false, "error": "Could not copy the selected paths."]
            }
            return ["ok": true, "count": paths.components(separatedBy: "\n").count]

        case "newFile":
            guard let suppliedName = args["name"] as? String,
                  let name = validatedFileName(suppliedName) else {
                return ["ok": false, "error": "Choose a valid file name."]
            }
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            guard execute("""
                tell application "Finder"
                    if not (exists front window) then error "No front Finder window."
                    set targetFolder to target of front window
                    make new file at targetFolder with properties {name:"\(escapedName)"}
                end tell
                """) != nil else {
                return ["ok": false, "error": "Could not create the file in the front Finder folder."]
            }
            return ["ok": true, "name": name]

        case "openTerminal":
            guard execute("""
                tell application "Finder"
                    if not (exists front window) then error "No front Finder window."
                    set folderPath to POSIX path of (target of front window as alias)
                end tell
                tell application "Terminal"
                    activate
                    do script "cd " & quoted form of folderPath
                end tell
                """) != nil else {
                return ["ok": false, "error": "Could not open Terminal at the front Finder folder."]
            }
            return ["ok": true]

        default:
            return HelperRouter.unknown(action)
        }
    }

    private static func validatedFileName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 240,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return nil }
        if (trimmed as NSString).pathExtension.isEmpty {
            return trimmed + ".txt"
        }
        return trimmed
    }

    private static func hasAutomationAccess(_ bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        // A false prompt flag checks existing consent without presenting a system prompt.
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
