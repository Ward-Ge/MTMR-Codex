//
//  TouchBarItems.swift
//  MTMR
//
//  Created by Anton Palgunov on 18/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

struct ItemAction {
    typealias TriggerClosure = (() -> Void)?
    
    let trigger: Action.Trigger
    let closure: TriggerClosure
    
    init(trigger: Action.Trigger, _ closure: TriggerClosure) {
        self.trigger = trigger
        self.closure = closure
    }
}

class CustomButtonTouchBarItem: NSCustomTouchBarItem, NSGestureRecognizerDelegate {
    
    var actions: [ItemAction] = [] {
        didSet {
            multiClick.isDoubleClickEnabled = actions.filter({ $0.trigger == .doubleTap }).count > 0
            multiClick.isTripleClickEnabled = actions.filter({ $0.trigger == .tripleTap }).count > 0
            longClick.isEnabled = actions.filter({ $0.trigger == .longTap }).count > 0
        }
    }
    var finishViewConfiguration: ()->() = {}
    
    private var button: NSButton!
    private var longClick: LongPressGestureRecognizer!
    private var multiClick: MultiClickGestureRecognizer!

    init(identifier: NSTouchBarItem.Identifier, title: String) {
        attributedTitle = title.defaultTouchbarAttributedString

        super.init(identifier: identifier)
        button = CustomHeightButton(title: title, target: nil, action: nil)

        longClick = LongPressGestureRecognizer(target: self, action: #selector(handleGestureLong))
        longClick.isEnabled = false
        longClick.allowedTouchTypes = .direct
        longClick.delegate = self
        
        multiClick = MultiClickGestureRecognizer(
            target: self,
            action: #selector(handleGestureSingleTap),
            doubleAction: #selector(handleGestureDoubleTap),
            tripleAction: #selector(handleGestureTripleTap)
        )
        multiClick.allowedTouchTypes = .direct
        multiClick.delegate = self
        multiClick.isDoubleClickEnabled = false
        multiClick.isTripleClickEnabled = false

        reinstallButton()
        button.attributedTitle = attributedTitle
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isBordered: Bool = true {
        didSet {
            reinstallButton()
        }
    }

    var backgroundColor: NSColor? {
        didSet {
            reinstallButton()
        }
    }

    var title: String {
        get {
            return attributedTitle.string
        }
        set {
            attributedTitle = newValue.defaultTouchbarAttributedString
        }
    }

    var attributedTitle: NSAttributedString {
        didSet {
            button?.imagePosition = attributedTitle.length > 0 ? .imageLeading : .imageOnly
            button?.attributedTitle = attributedTitle
        }
    }

    var image: NSImage? {
        didSet {
            button.image = image
        }
    }

    private func reinstallButton() {
        let title = button.attributedTitle
        let image = button.image
        let cell = CustomButtonCell(parentItem: self)
        button.cell = cell
        if let color = backgroundColor {
            cell.isBordered = true
            button.bezelColor = color
            button.bezelStyle = .rounded
            cell.backgroundColor = color
        } else {
            button.isBordered = isBordered
            button.bezelStyle = isBordered ? .rounded : .inline
        }
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.attributedTitle = title
        button?.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.image = image
        view = button

        view.addGestureRecognizer(longClick)
        // view.addGestureRecognizer(singleClick)
        view.addGestureRecognizer(multiClick)
        finishViewConfiguration()
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        if gestureRecognizer == multiClick && otherGestureRecognizer == longClick
            || gestureRecognizer == longClick && otherGestureRecognizer == multiClick // need it
        {
            return false
        }
        return true
    }
    
    func callActions(for trigger: Action.Trigger) {
        let itemActions = self.actions.filter { $0.trigger == trigger }
        for itemAction in itemActions {
            itemAction.closure?()
        }
    }
    
    @objc func handleGestureSingleTap() {
        callActions(for: .singleTap)
    }
    
    @objc func handleGestureDoubleTap() {
        callActions(for: .doubleTap)
    }
    
    @objc func handleGestureTripleTap() {
        callActions(for: .tripleTap)
    }

    @objc func handleGestureLong(gr: NSPressGestureRecognizer) {
        switch gr.state {
        case .possible: // tiny hack because we're calling action manually
            callActions(for: .longTap)
            break
        default:
            break
        }
    }

    fileprivate func restoreAppearanceAfterTouch() {
        restoreAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.restoreAppearance()
        }
    }

    private func restoreAppearance() {
        button.highlight(false)
        button.attributedTitle = attributedTitle
        button.needsDisplay = true
    }
}

class CustomHeightButton: NSButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = 30
        return size
    }
}

class CustomButtonCell: NSButtonCell {
    weak var parentItem: CustomButtonTouchBarItem?

    init(parentItem: CustomButtonTouchBarItem) {
        super.init(textCell: "")
        self.parentItem = parentItem
        wraps = true
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        if isBordered {
            super.highlight(flag, withFrame: cellFrame, in: controlView)
        } else if let parentItem = self.parentItem {
            attributedTitle = parentItem.attributedTitle
            controlView.needsDisplay = true
        }
    }
    
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        return rect // need that so content may better fit in button with very limited width
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        if attributedTitle.string.contains("\n") {
            return rect
        }
        return super.titleRect(forBounds: rect)
    }

    override func drawTitle(
        _ title: NSAttributedString,
        withFrame frame: NSRect,
        in controlView: NSView
    ) -> NSRect {
        guard title.string.contains("CodeX") else {
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }

        let titleString = title.string as NSString
        let filled = titleString.range(of: "▰")
        let empty = titleString.range(of: "▱")
        let firstProgressLocation = [filled, empty]
            .filter { $0.location != NSNotFound }
            .map { $0.location }
            .min()

        guard let prefixEnd = firstProgressLocation, prefixEnd > 0 else {
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }

        let isTwoLine = title.string.contains("\n")
        let contentOffsetX = isTwoLine
            ? DisplaySettings.contentOffsetX
            : DisplaySettings.contentOffsetX - DisplaySettings.defaultContentOffsetX
        let contentOffsetY = isTwoLine
            ? DisplaySettings.contentOffsetY
            : DisplaySettings.contentOffsetY - DisplaySettings.defaultContentOffsetY
        let contentFrame = frame.offsetBy(
            dx: CGFloat(contentOffsetX),
            dy: CGFloat(contentOffsetY)
        )

        let prefixRange = NSRange(location: 0, length: prefixEnd)
        let baseTitle = NSMutableAttributedString(attributedString: title)
        baseTitle.addAttribute(.foregroundColor, value: NSColor.clear, range: prefixRange)
        let result = super.drawTitle(baseTitle, withFrame: contentFrame, in: controlView)

        let overlayTitle = NSMutableAttributedString(attributedString: title)
        let fullRange = NSRange(location: 0, length: overlayTitle.length)
        overlayTitle.addAttribute(.foregroundColor, value: NSColor.clear, range: fullRange)
        title.enumerateAttribute(.foregroundColor, in: prefixRange) { value, range, _ in
            if let color = value as? NSColor {
                overlayTitle.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        _ = super.drawTitle(
            overlayTitle,
            withFrame: contentFrame.offsetBy(
                dx: CGFloat(DisplaySettings.codeXOffsetX),
                dy: CGFloat(DisplaySettings.codeXOffsetY)
            ),
            in: controlView
        )
        return result
    }

    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAttributedTitle(_ title: NSAttributedString, withColor color: NSColor) {
        let attrTitle = NSMutableAttributedString(attributedString: title)
        let fullRange = NSRange(location: 0, length: attrTitle.length)
        var transparentRanges: [NSRange] = []
        attrTitle.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if let currentColor = value as? NSColor, currentColor.alphaComponent == 0 {
                transparentRanges.append(range)
            }
        }

        attrTitle.addAttributes([.foregroundColor: color], range: fullRange)
        for range in transparentRanges {
            attrTitle.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
        attributedTitle = attrTitle
    }
}

// Thanks to https://stackoverflow.com/a/49843893
final class MultiClickGestureRecognizer: NSClickGestureRecognizer {

    private let _action: Selector
    private let _doubleAction: Selector
    private let _tripleAction: Selector
    private var _clickCount: Int = 0
    
    public var isDoubleClickEnabled = true
    public var isTripleClickEnabled = true

    override var action: Selector? {
        get {
            return nil /// prevent base class from performing any actions
        } set {
            if newValue != nil { // if they are trying to assign an actual action
                fatalError("Only use init(target:action:doubleAction) for assigning actions")
            }
        }
    }

    required init(target: AnyObject, action: Selector, doubleAction: Selector, tripleAction: Selector) {
        _action = action
        _doubleAction = doubleAction
        _tripleAction = tripleAction
        super.init(target: target, action: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(target:action:doubleAction:tripleAction) is only support atm")
    }
    
    override func touchesBegan(with event: NSEvent) {
        HapticFeedback.instance.tap(type: .click)
        super.touchesBegan(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        HapticFeedback.instance.tap(type: .back)
        super.touchesEnded(with: event)
        restoreTargetAppearance()
        _clickCount += 1
        
        var delayThreshold: TimeInterval // fine tune this as needed
        
        guard isDoubleClickEnabled || isTripleClickEnabled else {
            _ = target?.perform(_action)
            return
        }
        
        if (isTripleClickEnabled) {
            delayThreshold = 0.4
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 3 {
                _ = target?.perform(_tripleAction)
            }
        } else {
            delayThreshold = 0.3
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 2 {
                _ = target?.perform(_doubleAction)
            }
        }
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        restoreTargetAppearance()
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        _clickCount = 0
        restoreTargetAppearance()
    }

    private func restoreTargetAppearance() {
        (target as? CustomButtonTouchBarItem)?.restoreAppearanceAfterTouch()
    }

    @objc private func _resetAndPerformActionIfNecessary() {
        if _clickCount == 1 {
            _ = target?.perform(_action)
        }
        if isTripleClickEnabled && _clickCount == 2 {
            _ = target?.perform(_doubleAction)
        }
        _clickCount = 0
    }
}

class LongPressGestureRecognizer: NSPressGestureRecognizer {
    var recognizeTimeout = 0.4
    private var timer: Timer?
    
    override func touchesBegan(with event: NSEvent) {
        timerInvalidate()
        
        let touches = event.touches(for: self.view!)
        if touches.count == 1 { // to prevent it for built-in two/three-finger gestures
            timer = Timer.scheduledTimer(timeInterval: recognizeTimeout, target: self, selector: #selector(self.onTimer), userInfo: nil, repeats: false)
        }
        
        super.touchesBegan(with: event)
    }
    
    override func touchesMoved(with event: NSEvent) {
        timerInvalidate() // to prevent it for built-in two/three-finger gestures
        super.touchesMoved(with: event)
        restoreTargetAppearance()
    }
    
    override func touchesCancelled(with event: NSEvent) {
        timerInvalidate()
        super.touchesCancelled(with: event)
        restoreTargetAppearance()
    }
    
    override func touchesEnded(with event: NSEvent) {
        timerInvalidate()
        super.touchesEnded(with: event)
        restoreTargetAppearance()
    }

    private func restoreTargetAppearance() {
        (target as? CustomButtonTouchBarItem)?.restoreAppearanceAfterTouch()
    }
    
    private func timerInvalidate() {
        if let timer = timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    
    @objc private func onTimer() {
        if let target = self.target, let action = self.action {
            target.performSelector(onMainThread: action, with: self, waitUntilDone: false)
            HapticFeedback.instance.tap(type: .strong)
        }
    }
    
    deinit {
        timerInvalidate()
    }
}

extension String {
    var defaultTouchbarAttributedString: NSAttributedString {
        let attrTitle = NSMutableAttributedString(string: self, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .regular), .baselineOffset: 1])
        attrTitle.setAlignment(.center, range: NSRange(location: 0, length: count))
        return attrTitle
    }
}
