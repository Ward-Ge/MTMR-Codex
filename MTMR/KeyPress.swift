//
//  KeyPress.swift
//  MTMR
//
//  Created by Anton Palgunov on 17/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Foundation

protocol KeyPress {
    var keyCode: CGKeyCode { get }
    func send()
}

struct GenericKeyPress: KeyPress {
    var keyCode: CGKeyCode
}

enum EscapeKeyPress {
    static func send() {
        if #available(macOS 10.15, *), !CGPreflightPostEventAccess() {
            guard CGRequestPostEventAccess() else { return }
        }

        GenericKeyPress(keyCode: 53).send()
    }
}

extension KeyPress {
    func send() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)

        let loc: CGEventTapLocation = .cghidEventTap
        keyDown?.post(tap: loc)
        keyUp?.post(tap: loc)
    }
}

func HIDPostAuxKey(_ key: Int32) {
    let key = UInt8(key)
    MediaKeys.hidPostAuxKey(key)
}
