import AppKit

protocol RuntimeActivity: AnyObject {
    func start()
    func stop()
}

extension NetSpeedMonitor: RuntimeActivity {}
extension NowPlayingMonitor: RuntimeActivity {}
extension StockMonitor: RuntimeActivity {}
extension SerialLink: RuntimeActivity {}

extension UsageFetcher: RuntimeActivity {
    func start() {
        startAutoRefresh()
    }

    func stop() {
        stopAutoRefresh()
    }
}

final class AppRuntimeController {
    private let featurePreferences: FeaturePreferences
    private let alwaysOnActivities: [RuntimeActivity]
    private let featureActivities: [String: RuntimeActivity]
    private let notificationCenter: NotificationCenter
    private let pairingInterval: TimeInterval
    private let wakeDelay: TimeInterval
    private let pairingAction: () -> Void
    private let cancelPairingAction: () -> Void

    private var observerTokens: [NSObjectProtocol] = []
    private var pairingTimer: Timer?
    private var pendingWake: DispatchWorkItem?
    private(set) var isSuspended = true

    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    init(featurePreferences: FeaturePreferences,
         alwaysOnActivities: [RuntimeActivity],
         featureActivities: [String: RuntimeActivity],
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         pairingInterval: TimeInterval = 60,
         wakeDelay: TimeInterval = 2,
         pairingAction: @escaping () -> Void,
         cancelPairingAction: @escaping () -> Void) {
        self.featurePreferences = featurePreferences
        self.alwaysOnActivities = alwaysOnActivities
        self.featureActivities = featureActivities
        self.notificationCenter = notificationCenter
        self.pairingInterval = pairingInterval
        self.wakeDelay = wakeDelay
        self.pairingAction = pairingAction
        self.cancelPairingAction = cancelPairingAction
    }

    deinit {
        stop()
    }

    func start() {
        guard observerTokens.isEmpty else { return }
        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.prepareForSleep()
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleWake()
        })
        resumeAfterWake()
    }

    func stop() {
        pendingWake?.cancel()
        pendingWake = nil
        prepareForSleep()
        observerTokens.forEach(notificationCenter.removeObserver)
        observerTokens.removeAll()
    }

    func prepareForSleep() {
        pendingWake?.cancel()
        pendingWake = nil
        guard !isSuspended else { return }
        isSuspended = true
        onWillSleep?()
        pairingTimer?.invalidate()
        pairingTimer = nil
        cancelPairingAction()
        featureActivities.values.forEach { $0.stop() }
        alwaysOnActivities.forEach { $0.stop() }
        log("sleep: background activities paused")
    }

    func resumeAfterWake() {
        guard isSuspended else { return }
        isSuspended = false
        alwaysOnActivities.forEach { $0.start() }
        applyFeatureConfiguration()
        startPairingTimer()
        onDidWake?()
        log("wake: enabled activities resumed")
    }

    func applyFeatureConfiguration() {
        var enabledModes: [String] = []
        for (mode, activity) in featureActivities {
            if !isSuspended, featurePreferences.isEnabled(mode) {
                activity.start()
                enabledModes.append(mode)
            } else {
                activity.stop()
            }
        }
        if !isSuspended {
            log("features: \(enabledModes.sorted().joined(separator: ","))")
        }
    }

    private func scheduleWake() {
        pendingWake?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWake = nil
            self?.resumeAfterWake()
        }
        pendingWake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeDelay, execute: work)
    }

    private func startPairingTimer() {
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: pairingInterval, repeats: true) {
            [weak self] _ in
            guard let self = self, !self.isSuspended else { return }
            self.pairingAction()
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[runtime] \(message)\n".utf8))
    }
}
