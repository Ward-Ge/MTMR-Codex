import Foundation

struct AppSettings {
    @UserDefault(key: "com.toxblh.mtmr.settings.showControlStrip", defaultValue: false)
    static var showControlStripState: Bool
    
    @UserDefault(key: "com.toxblh.mtmr.settings.hapticFeedback", defaultValue: true)
    static var hapticFeedbackState: Bool
    
    @UserDefault(key: "com.toxblh.mtmr.settings.multitouchGestures", defaultValue: true)
    static var multitouchGestures: Bool
    
    @UserDefault(key: "com.toxblh.mtmr.blackListedApps", defaultValue: [])
    static var blacklistedAppIds: [String]
    
    @UserDefault(key: "com.toxblh.mtmr.dock.persistent", defaultValue: [])
    static var dockPersistentAppIds: [String]
}

struct DisplaySettings {
    static let didChange = Notification.Name("MTMRDisplaySettingsDidChange")

    static let defaultContentOffsetX = 70.0
    static let defaultContentOffsetY = 8.0
    static let defaultLineHeight = 11.0
    static let defaultCodeXFontSize = 13.0
    static let defaultCodeXOffsetX = 0.0
    static let defaultCodeXOffsetY = 0.0

    @UserDefault(key: "com.wardge.mtmr.display.contentOffsetX", defaultValue: defaultContentOffsetX)
    static var contentOffsetX: Double

    @UserDefault(key: "com.wardge.mtmr.display.contentOffsetY", defaultValue: defaultContentOffsetY)
    static var contentOffsetY: Double

    @UserDefault(key: "com.wardge.mtmr.display.lineHeight", defaultValue: defaultLineHeight)
    static var lineHeight: Double

    @UserDefault(key: "com.wardge.mtmr.display.codeXFontSize", defaultValue: defaultCodeXFontSize)
    static var codeXFontSize: Double

    @UserDefault(key: "com.wardge.mtmr.display.codeXOffsetX", defaultValue: defaultCodeXOffsetX)
    static var codeXOffsetX: Double

    @UserDefault(key: "com.wardge.mtmr.display.codeXOffsetY", defaultValue: defaultCodeXOffsetY)
    static var codeXOffsetY: Double

    @UserDefault(key: "com.wardge.mtmr.display.showFiveHour", defaultValue: true)
    static var showFiveHour: Bool

    @UserDefault(key: "com.wardge.mtmr.display.showWeekly", defaultValue: true)
    static var showWeekly: Bool

    static func reset() {
        contentOffsetX = defaultContentOffsetX
        contentOffsetY = defaultContentOffsetY
        lineHeight = defaultLineHeight
        codeXFontSize = defaultCodeXFontSize
        codeXOffsetX = defaultCodeXOffsetX
        codeXOffsetY = defaultCodeXOffsetY
        notifyChange()
    }

    static func notifyChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    var wrappedValue: T {
        get {
            return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
}
