//
//  ShellScriptTouchBarItem.swift
//  MTMR
//
//  Created by bobr on 08/08/2019.
//  Copyright © 2019 Anton Palgunov. All rights reserved.
//
import Foundation

class ShellScriptTouchBarItem: CustomButtonTouchBarItem {
    private let interval: TimeInterval
    private let source: String
    private var forceHideConstraint: NSLayoutConstraint!
    private var quotaCacheObserver: NSObjectProtocol?
    private var displaySettingsObserver: NSObjectProtocol?
    
    struct ScriptResult: Decodable {
        var title: String?
        var image: Source?
    }

    init?(identifier: NSTouchBarItem.Identifier, source: SourceProtocol, interval: TimeInterval) {
        self.interval = interval
        self.source = source.string ?? "echo No \"source\""
        super.init(identifier: identifier, title: "⏳")
        
        forceHideConstraint = view.widthAnchor.constraint(equalToConstant: 0)

        quotaCacheObserver = NotificationCenter.default.addObserver(
            forName: CodexQuotaService.cacheDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.shellScriptQueue.async {
                self?.refresh()
            }
        }

        displaySettingsObserver = NotificationCenter.default.addObserver(
            forName: DisplaySettings.didChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.shellScriptQueue.async {
                self?.refresh()
            }
        }
        
        DispatchQueue.shellScriptQueue.async {
            self.refreshAndSchedule()
        }
    }

    deinit {
        if let observer = quotaCacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = displaySettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func refreshAndSchedule() {
        refresh()

        DispatchQueue.shellScriptQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.refreshAndSchedule()
        }
    }

    private func refresh() {
        // Execute script and get result
        let scriptResult = execute(source)
        var rawTitle: String, image: NSImage?
        var json: Bool

        do {
            let decoder = JSONDecoder()
            let result = try decoder.decode(ScriptResult.self, from: scriptResult.data(using: .utf8)!)
            json = true
            rawTitle = result.title ?? ""
            image = result.image?.image
        } catch {
            json = false
            rawTitle = scriptResult
        }

        rawTitle = quotaTitleApplyingDisplaySelection(rawTitle)

        // Apply returned text attributes (if they were returned) to our result string
        let helper = AMR_ANSIEscapeHelper.init()
        helper.defaultStringColor = NSColor.white
        helper.font = "1".defaultTouchbarAttributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let title = NSMutableAttributedString.init(attributedString: helper.attributedString(withANSIEscapedString: rawTitle) ?? NSAttributedString(string: ""))
        let titleString = title.string as NSString
        let fullRange = NSRange(location: 0, length: titleString.length)
        let isTwoLine = title.string.contains("\n")

        func firstProgressLocation(in lineRange: NSRange) -> Int? {
            let filled = titleString.range(of: "▰", options: [], range: lineRange)
            let empty = titleString.range(of: "▱", options: [], range: lineRange)
            return [filled, empty]
                .filter { $0.location != NSNotFound }
                .map { $0.location }
                .min()
        }

        let regularFont = NSFont.systemFont(ofSize: isTwoLine ? 10.5 : 15, weight: .regular)
        let codeXFont = NSFont.systemFont(ofSize: CGFloat(DisplaySettings.codeXFontSize), weight: .semibold)
        let dataFont = NSFont.monospacedDigitSystemFont(
            ofSize: isTwoLine ? 10.5 : 15,
            weight: .regular
        )
        let filledFont = NSFont(name: "Menlo-Bold", size: isTwoLine ? 12 : 20) ?? NSFont.boldSystemFont(ofSize: isTwoLine ? 12 : 20)
        let emptyFont = NSFont(name: "Menlo-Regular", size: isTwoLine ? 8.5 : 11) ?? NSFont.systemFont(ofSize: isTwoLine ? 8.5 : 11)
        let filledAdvance = ("▰" as NSString).size(withAttributes: [.font: filledFont]).width
        let emptyAdvance = ("▱" as NSString).size(withAttributes: [.font: emptyFont]).width
        let emptyKern = max(0, filledAdvance - emptyAdvance)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isTwoLine ? .left : .center
        paragraph.lineBreakMode = .byClipping
        if isTwoLine {
            let lineHeight = CGFloat(DisplaySettings.lineHeight)
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        title.addAttributes([
            .font: regularFont,
            .baselineOffset: isTwoLine ? 0 : 1,
            .paragraphStyle: paragraph
        ], range: fullRange)

        let newlineRange = titleString.range(of: "\n")
        let firstLineLength = newlineRange.location == NSNotFound ? titleString.length : newlineRange.location
        let firstLineRange = NSRange(location: 0, length: firstLineLength)
        if let firstBar = firstProgressLocation(in: firstLineRange) {
            title.addAttribute(
                .font,
                value: codeXFont,
                range: NSRange(location: 0, length: firstBar)
            )
            if isTwoLine {
                title.addAttribute(
                    .baselineOffset,
                    value: -8.25,
                    range: NSRange(location: 0, length: firstBar)
                )
            }
        }

        if isTwoLine, newlineRange.location != NSNotFound {
            let secondLineStart = NSMaxRange(newlineRange)
            let secondLineRange = NSRange(location: secondLineStart, length: titleString.length - secondLineStart)
            if let secondBar = firstProgressLocation(in: secondLineRange) {
                title.addAttributes([
                    .font: codeXFont,
                    .foregroundColor: NSColor.clear,
                    .baselineOffset: 3
                ], range: NSRange(location: secondLineStart, length: secondBar - secondLineStart))
                title.addAttribute(
                    .baselineOffset,
                    value: 3,
                    range: NSRange(location: secondBar, length: titleString.length - secondBar)
                )
            }
        }

        let percentagePattern = try? NSRegularExpression(pattern: "(\\d{1,3})%")
        let percentageMatches = percentagePattern?.matches(in: title.string, range: fullRange) ?? []
        let remainingValues = percentageMatches.compactMap { match -> Int? in
            guard match.numberOfRanges > 1 else { return nil }
            return Int(titleString.substring(with: match.range(at: 1)))
        }
        let newlineLocation = titleString.range(of: "\n").location

        for match in percentageMatches {
            let lineEndSearch = NSRange(
                location: NSMaxRange(match.range),
                length: titleString.length - NSMaxRange(match.range)
            )
            let nextNewline = titleString.range(of: "\n", options: [], range: lineEndSearch)
            let lineEnd = nextNewline.location == NSNotFound ? titleString.length : nextNewline.location

            var lastProgress = match.range.location - 1
            while lastProgress >= 0 {
                let glyph = titleString.substring(with: NSRange(location: lastProgress, length: 1))
                if glyph == "▰" || glyph == "▱" {
                    break
                }
                lastProgress -= 1
            }

            if lastProgress >= 0 && lineEnd > lastProgress + 1 {
                title.addAttribute(
                    .font,
                    value: dataFont,
                    range: NSRange(location: lastProgress + 1, length: lineEnd - lastProgress - 1)
                )
            }
        }

        func progressColour(for remaining: Int) -> NSColor {
            let bounded = max(0, min(100, remaining))
            let colourStep = bounded == 0 ? 0 : min(9, (bounded - 1) / 10)
            return NSColor(
                calibratedHue: CGFloat(colourStep) / 27,
                saturation: 0.90,
                brightness: 1.0,
                alpha: 1.0
            )
        }

        for index in 0..<titleString.length {
            let range = NSRange(location: index, length: 1)
            let glyph = titleString.substring(with: range)
            if glyph == "▰" {
                let lineIndex = newlineLocation != NSNotFound && index > newlineLocation ? 1 : 0
                let lineBaseline: CGFloat = lineIndex == 1 ? 3 : 0
                let remaining = remainingValues.isEmpty
                    ? 0
                    : remainingValues[min(lineIndex, remainingValues.count - 1)]
                title.addAttributes([
                    .font: filledFont,
                    .kern: 0,
                    .foregroundColor: progressColour(for: remaining),
                    .baselineOffset: isTwoLine ? lineBaseline : -1
                ], range: range)
            } else if glyph == "▱" {
                let lineIndex = newlineLocation != NSNotFound && index > newlineLocation ? 1 : 0
                let lineBaseline: CGFloat = lineIndex == 1 ? 4 : 1
                title.addAttributes([
                    .font: emptyFont,
                    .kern: emptyKern,
                    .baselineOffset: isTwoLine ? lineBaseline : 2
                ], range: range)
            }
        }
        let newBackgoundColor: NSColor? = title.length != 0 ? title.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        
        // Update UI
        DispatchQueue.main.async { [weak self, newBackgoundColor] in
            if (newBackgoundColor != self?.backgroundColor) { // performance optimization because of reinstallButton
                self?.backgroundColor = newBackgoundColor
            }
            self?.attributedTitle = title
            if json {
                self?.image = image
            }
            self?.forceHideConstraint.isActive = scriptResult == ""
        }
    }

    private func quotaTitleApplyingDisplaySelection(_ rawTitle: String) -> String {
        let lines = rawTitle
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let isQuotaOutput = lines.count == 2 && lines.allSatisfy {
            $0.contains("CodeX") && ($0.contains("▰") || $0.contains("▱"))
        }
        guard isQuotaOutput else { return rawTitle }

        var visibleLines: [String] = []
        if DisplaySettings.showFiveHour {
            visibleLines.append(lines[0])
        }
        if DisplaySettings.showWeekly {
            visibleLines.append(lines[1])
        }
        return visibleLines.isEmpty ? lines[0] : visibleLines.joined(separator: "\n")
    }
    
    func execute(_ command: String) -> String {
        let task = Process()
        if let shell = getenv("SHELL") {
            task.launchPath = String.init(cString: shell)
        } else {
            task.launchPath = "/bin/bash"
        }
        task.arguments = ["-c", command]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        // kill process if it is over update interval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak task] in
            task?.terminate()
        }
        
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var output: String = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? ?? ""
        
        //always wait until task end or you can catch "task still running" error while accessing task.terminationStatus variable
        task.waitUntilExit()
        if (output == "" && task.terminationStatus != 0) {
            output = "error"
        }
        
        return output.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
    }
}

extension DispatchQueue {
    static let shellScriptQueue = DispatchQueue(label: "mtmr.shellscript")
}
