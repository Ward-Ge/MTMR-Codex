//
//  AppDelegate.swift
//  MTMR
//
//  Created by Anton Palgunov on 16/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa
import Carbon

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var isBlockedApp: Bool = false

    private var fileSystemSource: DispatchSourceFileSystemObject?
    private var displaySettingsWindowController: DisplaySettingsWindowController?
    private var statusItemHotKey: EventHotKeyRef?
    private var statusItemHotKeyHandler: EventHandlerRef?
    private var isShowingEscapePermissionHelp = false

    func applicationDidFinishLaunching(_: Notification) {
        AppSettings.configureMachineDefaults()
        CodexQuotaService.shared.start()
        TouchBarController.shared.setupControlStripPresence()

        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusImage")
        }
        createMenu()
        statusItem.isVisible = !AppSettings.hideStatusItemState
        registerStatusItemHotKey()

        if AppSettings.showVirtualEscapeKeyState {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                EscapeKeyPress.requestAccess()
                self.createMenu()
            }
        }

        reloadOnDefaultConfigChanged()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func applicationWillTerminate(_: Notification) {
        TouchBarController.shared.prepareForApplicationTermination()
        if let hotKey = statusItemHotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler = statusItemHotKeyHandler {
            RemoveEventHandler(handler)
        }
        CodexQuotaService.shared.stopSynchronously()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        revealStatusItem()
        return true
    }

    @objc func refreshCodexQuota(_: Any?) {
        CodexQuotaService.shared.refreshNow()
    }

    @objc func configureCodexRefreshInterval(_: Any?) {
        NSApp.activate(ignoringOtherApps: true)

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 86400

        let input = NSTextField(frame: NSRect(x: 30, y: 0, width: 45, height: 24))
        input.alignment = .right
        input.formatter = formatter
        input.integerValue = AppSettings.codexRefreshIntervalSeconds

        let unitLabel = NSTextField(labelWithString: "秒")
        unitLabel.frame = NSRect(x: 83, y: 3, width: 27, height: 18)

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
        accessoryView.addSubview(input)
        accessoryView.addSubview(unitLabel)

        let alert = NSAlert()
        alert.messageText = "Codex 自动刷新间隔"
        alert.informativeText = "请输入 1–86400 秒的整数。"
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let seconds = min(86400, max(1, input.integerValue))
        AppSettings.codexRefreshIntervalSeconds = seconds
        CodexQuotaService.shared.updateRefreshInterval()
        createMenu()
    }

    @objc func openDisplaySettings(_: Any?) {
        if displaySettingsWindowController == nil {
            displaySettingsWindowController = DisplaySettingsWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        displaySettingsWindowController?.showWindow(nil)
        displaySettingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func updateIsBlockedApp() {
        if let frontmostAppId = TouchBarController.shared.frontmostApplicationIdentifier {
            isBlockedApp = AppSettings.blacklistedAppIds.firstIndex(of: frontmostAppId) != nil
        } else {
            isBlockedApp = false
        }
        createMenu()
    }

    @objc func openPreferences(_: Any?) {
        let task = Process()
        let appSupportDirectory = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!.appending("/MTMR")
        let presetPath = appSupportDirectory.appending("/items.json")
        task.launchPath = "/usr/bin/open"
        task.arguments = [presetPath]
        task.launch()
    }

    @objc func toggleControlStrip(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.showControlStripState = item.state == .off
        TouchBarController.shared.resetControlStrip()
    }

    @objc func toggleBlackListedApp(_: Any?) {
        if let appIdentifier = TouchBarController.shared.frontmostApplicationIdentifier {
            if let index = TouchBarController.shared.blacklistAppIdentifiers.firstIndex(of: appIdentifier) {
                TouchBarController.shared.blacklistAppIdentifiers.remove(at: index)
            } else {
                TouchBarController.shared.blacklistAppIdentifiers.append(appIdentifier)
            }
            
            AppSettings.blacklistedAppIds = TouchBarController.shared.blacklistAppIdentifiers
            TouchBarController.shared.updateActiveApp()
            updateIsBlockedApp()
        }
    }

    @objc func toggleHapticFeedback(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.hapticFeedbackState = item.state == .on
    }

    @objc func toggleMultitouch(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.multitouchGestures = item.state == .on
        TouchBarController.shared.basicView?.legacyGesturesEnabled = item.state == .on
    }

    @objc func openPreset(_: Any?) {
        let dialog = NSOpenPanel()

        dialog.title = "Choose a items.json file"
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = true
        dialog.canChooseDirectories = false
        dialog.canCreateDirectories = false
        dialog.allowsMultipleSelection = false
        dialog.allowedFileTypes = ["json"]
        dialog.directoryURL = NSURL.fileURL(withPath: NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!.appending("/MTMR"), isDirectory: true)

        if dialog.runModal() == .OK, let path = dialog.url?.path {
            TouchBarController.shared.reloadPreset(path: path)
        }
    }

    @objc func toggleStartAtLogin(_: Any?) {
        LaunchAtLoginController().setLaunchAtLogin(!LaunchAtLoginController().launchAtLogin, for: NSURL.fileURL(withPath: Bundle.main.bundlePath))
        createMenu()
    }

    @objc func toggleVirtualEscapeKey(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.showVirtualEscapeKeyState = item.state == .on
        TouchBarController.shared.refreshTouchBar()
        if item.state == .on, !EscapeKeyPress.requestAccess() {
            showVirtualEscapePermissionHelp()
        }
        createMenu()
    }

    @objc func requestVirtualEscapePermission(_: Any?) {
        if !EscapeKeyPress.requestAccess() {
            showVirtualEscapePermissionHelp()
        } else {
            createMenu()
        }
    }

    func showVirtualEscapePermissionHelp() {
        guard !isShowingEscapePermissionHelp else { return }
        isShowingEscapePermissionHelp = true
        defer { isShowingEscapePermissionHelp = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要允许 MTMR 使用虚拟 Esc"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 MTMR。\n\n如果列表中已经有 MTMR，但 Esc 仍然无效，请先删除旧的 MTMR，再重新添加 /Applications/MTMR.app，随后退出并重新打开 MTMR。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    @objc func hideStatusItem(_: Any?) {
        AppSettings.hideStatusItemState = true
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.isVisible = false
        }
    }

    private func revealStatusItem() {
        guard !statusItem.isVisible else { return }
        AppSettings.hideStatusItemState = false
        statusItem.isVisible = true
        createMenu()
    }

    private func registerStatusItemHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event = event, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.id == 1 else { return noErr }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.revealStatusItem()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &statusItemHotKeyHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D_54_4D_52), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &statusItemHotKey
        )
    }

    func createMenu() {
        let menu = NSMenu()

        let startAtLogin = NSMenuItem(title: "开机启动", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        startAtLogin.state = LaunchAtLoginController().launchAtLogin ? .on : .off

        let hideControlStrip = NSMenuItem(title: "隐藏系统控制条", action: #selector(toggleControlStrip(_:)), keyEquivalent: "")
        hideControlStrip.state = AppSettings.showControlStripState ? .off : .on

        let hapticFeedback = NSMenuItem(title: "震动反馈", action: #selector(toggleHapticFeedback(_:)), keyEquivalent: "")
        hapticFeedback.state = AppSettings.hapticFeedbackState ? .on : .off

        let virtualEscapeKey = NSMenuItem(title: "虚拟 Esc 键", action: #selector(toggleVirtualEscapeKey(_:)), keyEquivalent: "")
        virtualEscapeKey.state = AppSettings.showVirtualEscapeKeyState ? .on : .off

        let hideStatusItem = NSMenuItem(title: "隐藏顶部图标", action: #selector(hideStatusItem(_:)), keyEquivalent: "m")
        hideStatusItem.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "刷新 Codex 额度", action: #selector(refreshCodexQuota(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "自动刷新间隔：\(AppSettings.codexRefreshIntervalSeconds) 秒…",
            action: #selector(configureCodexRefreshInterval(_:)),
            keyEquivalent: ""
        )
        menu.addItem(withTitle: "显示设置…", action: #selector(openDisplaySettings(_:)), keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())
        menu.addItem(hapticFeedback)
        menu.addItem(hideControlStrip)
        menu.addItem(virtualEscapeKey)
        if AppSettings.showVirtualEscapeKeyState, !EscapeKeyPress.hasAccess {
            menu.addItem(withTitle: "启用 Esc 权限…", action: #selector(requestVirtualEscapePermission(_:)), keyEquivalent: "")
        }
        menu.addItem(startAtLogin)
        menu.addItem(hideStatusItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func reloadOnDefaultConfigChanged() {
        let file = NSURL.fileURL(withPath: standardConfigPath)

        let fd = open(file.path, O_EVTONLY)

        fileSystemSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: DispatchQueue(label: "DefaultConfigChanged"))

        fileSystemSource?.setEventHandler(handler: {
            print("Config changed, reloading...")
            DispatchQueue.main.async {
                TouchBarController.shared.reloadPreset(path: file.path)
            }
        })

        fileSystemSource?.setCancelHandler(handler: {
            close(fd)
        })

        fileSystemSource?.resume()
    }
}

private final class DisplaySettingsWindowController: NSWindowController {
    private enum Setting: Int, CaseIterable {
        case contentOffsetX
        case contentOffsetY
        case lineHeight
        case codeXFontSize
        case codeXOffsetX
        case codeXOffsetY

        var title: String {
            switch self {
            case .contentOffsetX: return "整体左右位置"
            case .contentOffsetY: return "整体上下位置"
            case .lineHeight: return "两行高度间距"
            case .codeXFontSize: return "Codex 文字大小"
            case .codeXOffsetX: return "Codex 左右位置"
            case .codeXOffsetY: return "Codex 上下位置"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .contentOffsetX: return -200 ... 300
            case .contentOffsetY: return -20 ... 30
            case .lineHeight: return 6 ... 20
            case .codeXFontSize: return 8 ... 20
            case .codeXOffsetX: return -50 ... 50
            case .codeXOffsetY: return -20 ... 20
            }
        }

        var value: Double {
            switch self {
            case .contentOffsetX: return DisplaySettings.contentOffsetX
            case .contentOffsetY: return DisplaySettings.contentOffsetY
            case .lineHeight: return DisplaySettings.lineHeight
            case .codeXFontSize: return DisplaySettings.codeXFontSize
            case .codeXOffsetX: return DisplaySettings.codeXOffsetX
            case .codeXOffsetY: return DisplaySettings.codeXOffsetY
            }
        }

        func update(_ value: Double) {
            switch self {
            case .contentOffsetX: DisplaySettings.contentOffsetX = value
            case .contentOffsetY: DisplaySettings.contentOffsetY = value
            case .lineHeight: DisplaySettings.lineHeight = value
            case .codeXFontSize: DisplaySettings.codeXFontSize = value
            case .codeXOffsetX: DisplaySettings.codeXOffsetX = value
            case .codeXOffsetY: DisplaySettings.codeXOffsetY = value
            }
        }
    }

    private var sliders: [Setting: NSSlider] = [:]
    private var valueLabels: [Setting: NSTextField] = [:]
    private var showFiveHourButton: NSButton!
    private var showWeeklyButton: NSButton!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 405),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "显示设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let hint = NSTextField(labelWithString: "拖动滑块会立即更新 Touch Bar 显示")
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let displayTitle = NSTextField(labelWithString: "Bar 显示内容")
        displayTitle.alignment = .right
        displayTitle.widthAnchor.constraint(equalToConstant: 120).isActive = true

        showFiveHourButton = NSButton(
            checkboxWithTitle: "5 小时额度",
            target: self,
            action: #selector(displaySelectionChanged(_:))
        )
        showFiveHourButton.tag = 0
        showFiveHourButton.state = DisplaySettings.showFiveHour ? .on : .off

        showWeeklyButton = NSButton(
            checkboxWithTitle: "周额度",
            target: self,
            action: #selector(displaySelectionChanged(_:))
        )
        showWeeklyButton.tag = 1
        showWeeklyButton.state = DisplaySettings.showWeekly ? .on : .off

        let displayChoices = NSStackView(views: [showFiveHourButton, showWeeklyButton])
        displayChoices.orientation = .horizontal
        displayChoices.alignment = .centerY
        displayChoices.spacing = 24

        let displayRow = NSStackView(views: [displayTitle, displayChoices])
        displayRow.orientation = .horizontal
        displayRow.alignment = .centerY
        displayRow.spacing = 10
        stack.addArrangedSubview(displayRow)

        var normalizedExistingValue = false
        for setting in Setting.allCases {
            let currentValue = setting.value
            let initialValue = currentValue.rounded()
            if currentValue != initialValue {
                setting.update(initialValue)
                normalizedExistingValue = true
            }

            let title = NSTextField(labelWithString: setting.title)
            title.alignment = .right
            title.widthAnchor.constraint(equalToConstant: 120).isActive = true

            let slider = NSSlider(
                value: initialValue,
                minValue: setting.range.lowerBound,
                maxValue: setting.range.upperBound,
                target: self,
                action: #selector(sliderChanged(_:))
            )
            slider.tag = setting.rawValue
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
            sliders[setting] = slider

            let valueLabel = NSTextField(labelWithString: formatted(initialValue))
            valueLabel.alignment = .right
            valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
            valueLabels[setting] = valueLabel

            let row = NSStackView(views: [title, slider, valueLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            stack.addArrangedSubview(row)
        }

        if normalizedExistingValue {
            DisplaySettings.notifyChange()
        }

        let resetButton = NSButton(title: "恢复初始位置", target: self, action: #selector(resetSettings(_:)))
        resetButton.bezelStyle = .rounded
        let resetRow = NSStackView(views: [NSView(), resetButton])
        resetRow.orientation = .horizontal
        resetRow.distribution = .fill
        resetRow.widthAnchor.constraint(equalToConstant: 478).isActive = true
        stack.addArrangedSubview(resetRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let setting = Setting(rawValue: sender.tag) else { return }
        let value = sender.doubleValue.rounded()
        sender.doubleValue = value
        setting.update(value)
        valueLabels[setting]?.stringValue = formatted(value)
        DisplaySettings.notifyChange()
    }

    @objc private func displaySelectionChanged(_ sender: NSButton) {
        let showFiveHour = sender.tag == 0 ? sender.state == .on : showFiveHourButton.state == .on
        let showWeekly = sender.tag == 1 ? sender.state == .on : showWeeklyButton.state == .on

        guard showFiveHour || showWeekly else {
            sender.state = .on
            NSSound.beep()
            return
        }

        DisplaySettings.showFiveHour = showFiveHour
        DisplaySettings.showWeekly = showWeekly
        DisplaySettings.notifyChange()
    }

    @objc private func resetSettings(_: Any?) {
        DisplaySettings.reset()
        refreshControls()
    }

    private func refreshControls() {
        for setting in Setting.allCases {
            sliders[setting]?.doubleValue = setting.value
            valueLabels[setting]?.stringValue = formatted(setting.value)
        }
    }

    private func formatted(_ value: Double) -> String {
        return String(format: "%.0f", value)
    }
}
