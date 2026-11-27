// DictC: a menu bar popover that shows Claude, so you can use Claude's own
// voice typing anywhere and paste the result into the app you were in.
// Opening the popover clicks Claude's mic button for you (the only scripting
// of the page). "Paste back" sends the standard Select All and Cut commands,
// then Cmd+V. Esc or Discard throws the text away.

import AppKit
import WebKit
import Carbon.HIToolbox
import CoreAudio
import ServiceManagement

let homeURL = URL(string: "https://claude.ai/new")!

/// Appends a line to ~/Library/Logs/DictC.log (for working out why something failed).
func debugLog(_ text: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DictC.log")
    let line = "\(Date()) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Global hotkeys (Carbon; needs no special permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    init(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handlers[id] = handler
        HotKey.installIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4443_5443), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    private static func installIfNeeded() {
        if installed { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr, let handler = HotKey.handlers[hotKeyID.id] {
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Microphone routing
// Claude's page records from the system default input. While DictC is in use
// that is switched to the Mac's built-in mic, so Bluetooth earbuds are never
// pushed into their low-quality call mode. The previous input is put back
// once the popover is closed and recording has stopped.

enum MicRouter {
    private static var saved: AudioDeviceID?
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    private static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = device
        return AudioObjectSetPropertyData(system, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    static func builtInMic() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = address(kAudioDevicePropertyTransportType)
            guard AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streamsAddr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    /// Makes the built-in mic the system input, remembering what it replaced.
    static func useBuiltIn() {
        guard let builtIn = builtInMic() else { debugLog("no built-in mic found"); return }
        guard let current = defaultInput(), current != builtIn else { return }
        if setDefaultInput(builtIn) {
            if saved == nil { saved = current }
            debugLog("input switched to built-in mic (was device \(current))")
        } else {
            debugLog("could not switch input to built-in mic")
        }
    }

    static func restore() {
        guard let previous = saved else { return }
        saved = nil
        setDefaultInput(previous)
        debugLog("input restored to device \(previous)")
    }
}

// MARK: - Popover content: Claude plus a small native bar

final class PanelController: NSViewController, WKUIDelegate {
    let webView: WKWebView
    let statusLabel = NSTextField(labelWithString: "")
    var onPasteBack: (() -> Void)?
    var onDiscard: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps you signed in between launches
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 600))

        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        let pasteButton = NSButton(title: "Paste into last app", target: self, action: #selector(pasteTapped))
        pasteButton.bezelStyle = .rounded
        pasteButton.keyEquivalent = ""
        let newButton = NSButton(title: "Discard", target: self, action: #selector(discardTapped))
        newButton.bezelStyle = .rounded

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [pasteButton, newButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        webView.load(URLRequest(url: homeURL))
    }

    @objc func pasteTapped() { onPasteBack?() }
    @objc func discardTapped() { onDiscard?() }

    // Helpers shared by the two page scripts. Claude's buttons are found by
    // their accessibility labels: "Dictate", "Finish dictation", "Cancel dictation".
    private static let scriptPrelude = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const label = b => (b.getAttribute('aria-label') || b.title || '').trim();
        const find = re => [...document.querySelectorAll('button')]
          .find(b => !b.disabled && b.offsetParent !== null && re.test(label(b)));
        const press = el => {
          const r = el.getBoundingClientRect();
          const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                       clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
          const pointer = { ...at, pointerId: 1, pointerType: 'mouse', isPrimary: true };
          el.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1 }));
          el.dispatchEvent(new MouseEvent('mousedown', { ...at, buttons: 1 }));
          el.dispatchEvent(new PointerEvent('pointerup', pointer));
          el.dispatchEvent(new MouseEvent('mouseup', at));
          el.dispatchEvent(new MouseEvent('click', at));
        };
        const active = /^(finish|cancel) dictation/i;
        const voiceLabels = () => [...document.querySelectorAll('button')].map(label)
          .filter(l => /dictat|microphone|voice/i.test(l)).join(' | ');

        """

    private func runScript(_ body: String, completion: @escaping (String?) -> Void) {
        webView.callAsyncJavaScript(PanelController.scriptPrelude + body, arguments: [:],
                                    in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion(value as? String)
            case .failure(let error):
                debugLog("script failed: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    /// Waits for Claude's Dictate button and clicks it. A page that is still
    /// loading drops the script, so that case is retried.
    func startListening(triesLeft: Int = 6) {
        let js = """
        if (window.__dictcPolling) return 'busy';
        window.__dictcPolling = true;
        try {
          const deadline = Date.now() + 8000;
          while (Date.now() < deadline) {
            if (find(active)) return 'already';
            const hit = find(/^dictate$/i) || find(/dictat/i);
            if (hit) {
              press(hit);
              const until = Date.now() + 4000;
              while (Date.now() < until && !find(active)) await sleep(100);
              return (find(active) ? 'started' : 'no-start') + ' via ' + label(hit) + ' -> ' + voiceLabels();
            }
            await sleep(300);
          }
          return 'none: ' + voiceLabels();
        } finally { window.__dictcPolling = false; }
        """
        runScript(js) { [weak self] outcome in
            guard let self = self else { return }
            debugLog("startListening: \(outcome ?? "nil") capture=\(self.webView.microphoneCaptureState.rawValue)")
            guard let outcome = outcome else {
                if triesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startListening(triesLeft: triesLeft - 1) }
                } else {
                    self.say("Couldn't start the mic. Click it in Claude's box.")
                }
                return
            }
            if outcome.hasPrefix("started") || outcome == "already" {
                self.say("Listening. Esc discards.")
            } else if outcome != "busy" {
                self.say("Couldn't start the mic. Click it in Claude's box.")
            }
        }
    }

    /// Clicks "Finish dictation" if a recording is running, waits for the
    /// words to land in Claude's text box, and puts the cursor there.
    func finishDictation(completion: @escaping () -> Void) {
        let js = """
        const box = () => document.querySelector('[contenteditable="true"]');
        let did = 'idle';
        const finish = find(/^finish dictation/i);
        if (finish) {
          did = 'finished';
          press(finish);
          let until = Date.now() + 15000;
          while (Date.now() < until && find(active)) await sleep(100);
          until = Date.now() + 5000;
          while (Date.now() < until && !(box() && box().innerText.trim())) await sleep(100);
          await sleep(200);
        }
        if (did === 'idle') {
          const until = Date.now() + 1500;   // dictation may have only just ended
          while (Date.now() < until && !(box() && box().innerText.trim())) await sleep(100);
        }
        if (box()) box().focus();
        return did + ' text=' + (box() ? box().innerText.trim().length : -1);
        """
        runScript(js) { outcome in
            debugLog("finishDictation: \(outcome ?? "nil")")
            completion()
        }
    }

    @objc func goHome() { webView.load(URLRequest(url: homeURL)) }
    @objc func reload() { webView.reload() }

    func say(_ text: String) { statusLabel.stringValue = text }

    // Microphone: allowed for Claude's own pages only.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        let isClaude = host == "claude.ai" || host.hasSuffix(".claude.ai")
        debugLog("media permission asked: host=\(host) type=\(type.rawValue)")
        decisionHandler(isClaude && type == .microphone ? .grant : .deny)
    }

    // Links that want a new window open in this same view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var micObservation: NSKeyValueObservation?
    private var closeCount = 0
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panel = PanelController()
    private var lastApp: NSRunningApplication?
    private var hotKeys: [HotKey] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        debugLog("launched from \(Bundle.main.bundlePath), accessibility trusted=\(AXIsProcessTrusted())")
        enableLoginItemOnce()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "DictC")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "DictC: Control+Option+Space to open, Control+Option+Return to paste back"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 600)
        popover.contentViewController = panel
        popover.delegate = self
        _ = panel.view   // load Claude now, so the first open doesn't wait for the page
        micObservation = panel.webView.observe(\.microphoneCaptureState) { [weak self] webView, _ in
            debugLog("microphoneCaptureState=\(webView.microphoneCaptureState.rawValue)")
            DispatchQueue.main.async { self?.restoreMicIfIdle() }
        }
        panel.onPasteBack = { [weak self] in self?.pasteBack() }
        panel.onDiscard = { [weak self] in self?.discard() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.popover.isShown, event.keyCode == UInt16(kVK_Escape) else { return event }
            self.discard()
            return nil
        }

        lastApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let mods = controlKey | optionKey
        hotKeys.append(HotKey(id: 1, keyCode: kVK_Space, modifiers: mods) { [weak self] in
            self?.togglePopover()
        })
        hotKeys.append(HotKey(id: 2, keyCode: kVK_Return, modifiers: mods) { [weak self] in
            self?.pasteBack()
        })
    }

    /// Opening DictC again while it is running shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPopover(listen: true) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { MicRouter.restore() }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastApp = app
        }
    }

    // MARK: Microphone routing

    func popoverDidClose(_ notification: Notification) {
        restoreMicIfIdle()
        // A recording left running with the popover closed keeps the mic on.
        // After a minute, finish it; the words stay in Claude's box.
        closeCount += 1
        let thisClose = closeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self, self.closeCount == thisClose, !self.popover.isShown,
                  self.panel.webView.microphoneCaptureState != .none else { return }
            debugLog("recording left running for 60s with the popover closed; finishing it")
            self.panel.finishDictation { }
        }
    }

    // MARK: Open at login

    /// Turns "Open at login" on the first time DictC runs from Applications.
    /// After that the right-click menu item is the only thing that changes it.
    private func enableLoginItemOnce() {
        let key = "loginItemConfigured"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            debugLog("open at login: enabled")
        } catch {
            debugLog("open at login: could not enable: \(error)")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            debugLog("open at login: toggle failed: \(error)")
        }
        debugLog("open at login: status=\(SMAppService.mainApp.status.rawValue)")
    }

    private func restoreMicIfIdle() {
        if !popover.isShown && panel.webView.microphoneCaptureState == .none { MicRouter.restore() }
    }

    // MARK: Status item

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Paste into last app", action: #selector(pasteBackFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New chat", action: #selector(PanelController.goHome), keyEquivalent: "").target = panel
            menu.addItem(withTitle: "Reload", action: #selector(PanelController.reload), keyEquivalent: "").target = panel
            menu.addItem(.separator())
            let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(withTitle: "Quit DictC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func pasteBackFromMenu() { pasteBack() }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover(listen: true) }
    }

    /// Throws away the recording and any text (by loading a fresh chat), then
    /// returns to the app you were in.
    private func discard() {
        panel.goHome()
        popover.performClose(nil)
        if let target = lastApp, !target.isTerminated { target.activate(options: []) }
    }

    private func showPopover(listen: Bool) {
        guard let button = statusItem.button else { return }
        panel.say("")
        MicRouter.useBuiltIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(panel.webView)
        }
        if listen { panel.startListening() }
    }

    // MARK: Paste back

    /// Cuts whatever is in Claude's text box (Select All, then Cut: the same
    /// commands as Cmd+A and Cmd+X), goes back to the app you were in, and
    /// presses Cmd+V there.
    private func pasteBack() {
        if !popover.isShown {
            showPopover(listen: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.cutThenPaste() }
        } else {
            cutThenPaste()
        }
    }

    private func cutThenPaste() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeFirstResponder(panel.webView)
        panel.say("Finishing…")
        panel.finishDictation { [weak self] in
            guard let self = self else { return }
            self.panel.say("")
            let before = NSPasteboard.general.changeCount
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            }
            self.waitForClipboard(changedFrom: before, triesLeft: 15)
        }
    }

    private func waitForClipboard(changedFrom before: Int, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if NSPasteboard.general.changeCount != before {
                self.finishPaste()
            } else if triesLeft > 0 {
                self.waitForClipboard(changedFrom: before, triesLeft: triesLeft - 1)
            } else {
                self.panel.say("Nothing copied. Click in Claude's text box, then try again.")
            }
        }
    }

    private func finishPaste() {
        guard let target = lastApp, !target.isTerminated else {
            panel.say("Copied. Press Cmd+V where you want it.")
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        popover.performClose(nil)
        target.activate(options: [])
        guard trusted else { return }   // text stays on the clipboard; macOS shows how to allow DictC
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Menu (hidden for a menu bar app, but it makes Cmd+C / Cmd+V work)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DictC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
