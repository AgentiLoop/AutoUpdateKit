//
//  UpdatePrompt.swift
//  AutoUpdateKit
//
//  Extracted from StarPlayrXMac's Updater.swift.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import AppKit

/// Icon, title, message and up to three buttons (the first is the default, the last takes Esc),
/// shown without `runModal()` so the app keeps running while it is up. Returns the button index.
@MainActor
public enum UpdatePrompt {
    @discardableResult
    public static func ask(title: String, message: String, buttons: [String]) async -> Int {
        let width: CGFloat = 400, margin: CGFloat = 20
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: 0))
        var views: [NSView] = []
        var x = width + margin
        var controls: [NSButton] = []
        for (i, name) in buttons.enumerated() {
            let b = NSButton(title: name, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.sizeToFit()
            b.frame.size.width = max(b.frame.width + 16, 90)
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: margin)
            x -= 8
            b.tag = i
            if i == 0 { b.keyEquivalent = "\r" }
            if i == buttons.count - 1, buttons.count > 1 { b.keyEquivalent = "\u{1b}" }
            controls.append(b)
            views.append(b)
        }
        var y = margin + 32 + 20
        let info = NSTextField(wrappingLabelWithString: message)
        info.isSelectable = false
        let infoHeight = info.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 40
        info.frame = NSRect(x: margin, y: y, width: width, height: infoHeight)
        y += infoHeight + 10
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: margin, y: y)
        y += heading.frame.height + 14
        let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        icon.setAccessibilityElement(false)   // decoration: the heading says what this is about
        y += 64 + 28
        content.frame.size.height = y
        for v in views + [info, heading, icon] {
            v.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(v)
        }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.contentView = content
        window.level = .modalPanel
        window.center()
        // Keyboard and VoiceOver start on the default button (Update / OK).
        window.initialFirstResponder = controls.first
        let responder = Responder(window: window)
        for b in controls {
            b.target = responder
            b.action = #selector(Responder.pressed(_:))
        }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            responder.continuation = continuation
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private final class Responder: NSObject {
        let window: NSWindow
        var continuation: CheckedContinuation<Int, Never>?
        private var retainSelf: Responder?

        init(window: NSWindow) {
            self.window = window
            super.init()
            retainSelf = self
        }

        @objc func pressed(_ sender: NSButton) {
            window.orderOut(nil)
            continuation?.resume(returning: sender.tag)
            continuation = nil
            retainSelf = nil
        }
    }
}

/// Small floating "Downloading… / Installing…" window; also the download's progress delegate.
@MainActor
final class ProgressWindow: NSObject, URLSessionDownloadDelegate {
    private let window: NSWindow
    private let label: NSTextField
    private let bar: NSProgressIndicator

    init(title: String) {
        let width: CGFloat = 320, margin: CGFloat = 20
        label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: margin, y: margin + 28, width: width, height: 20)
        bar = NSProgressIndicator(frame: NSRect(x: margin, y: margin, width: width, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.setAccessibilityLabel(title)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: margin * 2 + 48 + 10))
        for v in [label, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(v)
        }
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.level = .modalPanel
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        super.init()
    }

    func show() {
        window.center()
        bar.startAnimation(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.orderOut(nil) }

    func set(text: String, indeterminate: Bool) {
        label.stringValue = text
        window.title = text
        bar.setAccessibilityLabel(text)
        bar.isIndeterminate = indeterminate
        if indeterminate { bar.startAnimation(nil) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.bar.isIndeterminate = false
            self.bar.doubleValue = fraction
        }
    }

    // The async download(for:) API hands back the file itself; nothing to do here.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
