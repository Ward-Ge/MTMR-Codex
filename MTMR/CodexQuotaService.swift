//
//  CodexQuotaService.swift
//  MTMR
//
//  Keeps the Codex quota display fresh without Python, launchd, or fixed user paths.
//

import Cocoa

final class CodexQuotaService {
    static let shared = CodexQuotaService()
    static let cacheDidChange = Notification.Name("MTMRCodexQuotaCacheDidChange")

    private enum ServiceError: LocalizedError {
        case helperNotFound
        case serverUnavailable
        case requestTimedOut
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .helperNotFound:
                return "Codex helper was not found"
            case .serverUnavailable:
                return "Codex app server is unavailable"
            case .requestTimedOut:
                return "Codex request timed out"
            case .invalidResponse:
                return "Codex returned an invalid response"
            case let .server(message):
                return message
            }
        }
    }

    private typealias JSON = [String: Any]
    private typealias ResponseHandler = (Result<JSON, Error>) -> Void

    private let queue = DispatchQueue(label: "com.wardge.mtmr.codex-quota")
    private let requestTimeout: TimeInterval = 20
    private let cacheURL = URL(fileURLWithPath: appSupportDirectory, isDirectory: true)
        .appendingPathComponent("codex-quota.txt")

    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()
    private var initialized = false
    private var isStopping = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var loginInFlight = false
    private var nextRequestID = 1
    private var readyHandlers: [(Bool) -> Void] = []
    private var responseHandlers: [Int: ResponseHandler] = [:]

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            self.isStopping = false
            self.removeLegacyUpdaterIfNeeded()
            self.createInitialCacheIfNeeded()
            self.refresh()
            self.scheduleRefreshTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopService()
        }
    }

    func stopSynchronously() {
        queue.sync { [weak self] in
            self?.stopService()
        }
    }

    private func stopService() {
        isStopping = true
        timer?.cancel()
        timer = nil
        refreshPending = false
        stopServer(error: ServiceError.serverUnavailable)
    }

    func refreshNow() {
        queue.async { [weak self] in
            self?.refresh()
        }
    }

    func updateRefreshInterval() {
        queue.async { [weak self] in
            guard let self = self, self.timer != nil else { return }
            self.scheduleRefreshTimer()
            self.refresh()
        }
    }

    private func scheduleRefreshTimer() {
        timer?.cancel()

        let interval = TimeInterval(max(1, AppSettings.codexRefreshIntervalSeconds))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            wallDeadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(min(5, max(1, Int(interval / 10))))
        )
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        self.timer = timer
        timer.resume()
    }

    func login() {
        queue.async { [weak self] in
            guard let self = self, !self.loginInFlight else { return }
            self.loginInFlight = true
            self.ensureServer { [weak self] ready in
                guard let self = self else { return }
                guard ready else {
                    self.loginInFlight = false
                    self.showAlert(
                        title: "未找到 Codex",
                        message: "请先安装并登录 Codex App、ChatGPT App 或 Codex CLI，然后重试。"
                    )
                    return
                }

                self.sendRequest(
                    method: "account/login/start",
                    params: [
                        "type": "chatgpt",
                        "useHostedLoginSuccessPage": true,
                        "appBrand": "codex"
                    ]
                ) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case let .success(message):
                        guard
                            let payload = message["result"] as? JSON,
                            let authURLString = payload["authUrl"] as? String,
                            let authURL = URL(string: authURLString)
                        else {
                            self.loginInFlight = false
                            self.showAlert(title: "无法登录 Codex", message: "没有收到有效的登录地址。")
                            return
                        }
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(authURL)
                        }
                    case let .failure(error):
                        self.loginInFlight = false
                        self.showAlert(title: "无法登录 Codex", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func refresh() {
        guard !isStopping else { return }
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        requestQuota(restartOnFailure: true)
    }

    private func requestQuota(restartOnFailure: Bool) {
        ensureServer { [weak self] ready in
            guard let self = self else { return }
            guard ready else {
                self.finishRefresh()
                return
            }

            self.sendRequest(method: "account/rateLimits/read", params: nil) { [weak self] result in
                guard let self = self else { return }
                guard case let .success(message) = result,
                    let payload = message["result"] as? JSON,
                    CodexQuotaSnapshot(payload: payload) != nil
                else {
                    if restartOnFailure, !self.isStopping {
                        self.stopServer(error: ServiceError.serverUnavailable)
                        self.requestQuota(restartOnFailure: false)
                        return
                    }
                    self.finishRefresh()
                    // Keep the last successful cache after the one automatic retry fails.
                    return
                }
                if CodexQuotaSnapshot.planType(in: payload) == nil {
                    // Older rate-limit responses omit the plan. Read it from the
                    // same temporary connection, without reading local credentials.
                    self.sendRequest(method: "account/read", params: ["refreshToken": false]) { [weak self] result in
                        guard let self = self else { return }
                        var plan: String?
                        if case let .success(message) = result,
                            let accountPayload = message["result"] as? JSON,
                            let account = accountPayload["account"] as? JSON {
                            plan = account["planType"] as? String
                        }
                        self.cacheQuota(payload, accountPlan: plan)
                    }
                } else {
                    self.cacheQuota(payload, accountPlan: nil)
                }
            }
        }
    }

    private func cacheQuota(_ payload: JSON, accountPlan: String?) {
        if let snapshot = CodexQuotaSnapshot(payload: payload, accountPlan: accountPlan),
            let data = try? JSONEncoder().encode(CodexQuotaSnapshot.Cache(
                title: snapshot.title(),
                codexQuota: snapshot
            )),
            let text = String(data: data, encoding: .utf8) {
            writeCache(text + "\n")
        }
        finishRefresh()
    }

    var currentQuota: CodexQuotaSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return (try? JSONDecoder().decode(CodexQuotaSnapshot.Cache.self, from: data))?.codexQuota
    }

    private func finishRefresh() {
        // MTMR is only an external reader. End the temporary Codex connection after
        // every read so the next refresh always uses the account currently active in Codex.
        stopServer(error: ServiceError.serverUnavailable)
        refreshInFlight = false
        guard refreshPending, !isStopping else { return }
        refreshPending = false
        refresh()
    }

    private func ensureServer(_ completion: @escaping (Bool) -> Void) {
        if initialized, process?.isRunning == true {
            completion(true)
            return
        }

        readyHandlers.append(completion)
        guard process == nil else { return }

        guard let helper = resolveHelper() else {
            finishServerStart(success: false)
            return
        }

        let task = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        task.executableURL = helper.url
        task.arguments = helper.arguments
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consume(data)
            }
        }

        task.terminationHandler = { [weak self, weak task] _ in
            guard let self = self, let task = task else { return }
            self.queue.async { [weak self] in
                guard let self = self, self.process === task else { return }
                self.stopServer(error: ServiceError.serverUnavailable)
            }
        }

        process = task
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)

        do {
            try task.run()
        } catch {
            stopServer(error: error)
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "mtmr_codex_quota",
                    "title": "MTMR Codex Quota",
                    "version": version
                ]
            ]
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.initialized = true
                self.sendNotification(method: "initialized", params: [:])
                self.finishServerStart(success: true)
            case let .failure(error):
                self.stopServer(error: error)
            }
        }
    }

    private func finishServerStart(success: Bool) {
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0(success) }
    }

    private func stopServer(error: Error) {
        let handlers = responseHandlers.values
        responseHandlers.removeAll()
        handlers.forEach { $0(.failure(error)) }

        finishServerStart(success: false)
        outputHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        outputHandle?.closeFile()

        let activeProcess = process
        process = nil
        inputHandle = nil
        outputHandle = nil
        initialized = false
        outputBuffer.removeAll(keepingCapacity: false)

        if activeProcess?.isRunning == true {
            activeProcess?.terminationHandler = nil
            activeProcess?.terminate()
        }
    }

    private func sendRequest(method: String, params: JSON?, completion: @escaping ResponseHandler) {
        guard inputHandle != nil else {
            completion(.failure(ServiceError.serverUnavailable))
            return
        }

        let requestID = nextRequestID
        nextRequestID += 1
        var message: JSON = ["id": requestID, "method": method]
        if let params = params {
            message["params"] = params
        }

        responseHandlers[requestID] = completion
        guard send(message) else {
            responseHandlers.removeValue(forKey: requestID)
            completion(.failure(ServiceError.serverUnavailable))
            return
        }

        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self = self,
                let handler = self.responseHandlers.removeValue(forKey: requestID)
            else { return }
            handler(.failure(ServiceError.requestTimedOut))
        }
    }

    private func sendNotification(method: String, params: JSON) {
        _ = send(["method": method, "params": params])
    }

    private func send(_ message: JSON) -> Bool {
        guard let inputHandle = inputHandle,
            JSONSerialization.isValidJSONObject(message),
            var data = try? JSONSerialization.data(withJSONObject: message)
        else { return false }
        data.append(0x0A)
        inputHandle.write(data)
        return true
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let message = object as? JSON
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        if let number = message["id"] as? NSNumber {
            let requestID = number.intValue
            guard let handler = responseHandlers.removeValue(forKey: requestID) else { return }
            if let error = message["error"] as? JSON {
                let text = error["message"] as? String ?? "Codex request failed"
                handler(.failure(ServiceError.server(text)))
            } else {
                handler(.success(message))
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "account/login/completed",
            let params = message["params"] as? JSON
        {
            loginInFlight = false
            if (params["success"] as? Bool) == true {
                refresh()
            } else if let error = params["error"] as? String {
                showAlert(title: "Codex 登录失败", message: error)
            }
        }
    }

    private func createInitialCacheIfNeeded() {
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        writeCache("✦ CodeX  正在读取额度\n")
    }

    private func removeLegacyUpdaterIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgent = home
            .appendingPathComponent("Library/LaunchAgents/com.codex.touchbar-quota.plist")
        let legacyScript = home
            .appendingPathComponent("Library/Application Support/MTMR/codex_touchbar_mtmr_update.py")

        guard
            let data = try? Data(contentsOf: launchAgent),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? JSON,
            propertyList["Label"] as? String == "com.codex.touchbar-quota",
            let arguments = propertyList["ProgramArguments"] as? [String],
            arguments.contains(where: { $0.hasSuffix("codex_touchbar_mtmr_update.py") })
        else { return }

        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())", launchAgent.path]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        try? launchctl.run()
        launchctl.waitUntilExit()

        try? FileManager.default.removeItem(at: launchAgent)
        try? FileManager.default.removeItem(at: legacyScript)
    }

    private func writeCache(_ text: String) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try text.write(to: cacheURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: CodexQuotaService.cacheDidChange, object: nil)
            }
        } catch {
            // Touch Bar keeps displaying the previous successful cache.
        }
    }

    private func resolveHelper() -> (url: URL, arguments: [String])? {
        let fileManager = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/codex-app-server")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return (bundled, [])
        }

        let home = fileManager.homeDirectoryForCurrentUser
        var appURLs = ["com.openai.codex", "com.openai.chat"].compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        for name in ["Codex.app", "ChatGPT.app"] {
            appURLs.append(URL(fileURLWithPath: "/Applications/\(name)"))
            appURLs.append(home.appendingPathComponent("Applications/\(name)"))
        }

        // Prefer the actual executable in the new nested bundle, then its wrapper
        // and the legacy layout used by older desktop releases.
        let cliPaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex"
        ]
        var candidates = appURLs.flatMap { appURL in
            cliPaths.map { appURL.appendingPathComponent($0) }
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        candidates.append(home.appendingPathComponent(".local/bin/codex"))

        if let cli = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return (cli, ["app-server", "--stdio"])
        }
        return nil
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }
}
