import BackgroundTasks
import Foundation
import StikPairFFI
import UserNotifications

@MainActor
final class PairingController: ObservableObject {

    static let shared = PairingController()
    static let taskIdentifier = "com.stik.StikPair.pairing"

    enum Phase: Equatable {
        case idle
        case waiting
        case showPin(String)
        case success(PairedDevice)
        case failed(String)
    }

    struct PairedDevice: Equatable {
        var name: String
        var model: String
        var udid: String
        var pairingFilePath: String
    }

    @Published var phase: Phase = .idle

    private let bindAddress = "0.0.0.0"
    private let hostName = "StikPair"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()

    private var bgTask: BGContinuedProcessingTask?
    private var pairingStarted = false
    private var taskFinished = false

    var isRunning: Bool {
        switch phase {
        case .waiting, .showPin: return true
        default: return false
        }
    }

    nonisolated func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PairingController.taskIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                PairingController.shared.runPairing(task: task)
            }
        }
    }

    // MARK: - Flow

    func start() {
        guard !isRunning else { return }
        phase = .waiting

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task {
            guard await localNetwork.request() else {
                phase = .failed("Local Network permission is required. Enable it in Settings › StikPair › Local Network, then try again.")
                return
            }
            submitBackgroundTask()
        }
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
    }

    private func submitBackgroundTask() {
        let request = BGContinuedProcessingTaskRequest(
            identifier: PairingController.taskIdentifier,
            title: "StikPair",
            subtitle: "Waiting for a device to connect…")
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.pairingStarted else { return }
                self.runPairing(task: nil)
            }
        } catch {
            runPairing(task: nil)
        }
    }

    private func runPairing(task: BGContinuedProcessingTask?) {
        guard !pairingStarted else { return }
        pairingStarted = true
        taskFinished = false
        bgTask = task

        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = 5
        task?.expirationHandler = { [weak self] in
            guard let self else { return }
            self.finishTask(success: false)
            if self.isRunning {
                self.phase = .failed("Background time expired before a device connected. Tap Pair to try again.")
            }
        }

        let bind = bindAddress
        let name = hostName
        let outPath = Self.pairingFilePath()
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = StikPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    "Mac17,7".withCString { modelC in
                        outPath.withCString { outC in
                            stikpair_run_host(
                                bindC, 0, nameC, modelC, outC,
                                readyCallback, pinCallback, ctx, &result)
                        }
                    }
                }
            }

            let outcome: Phase
            if rc == 0 {
                outcome = .success(PairedDevice(
                    name: cString(result.device_name),
                    model: cString(result.device_model),
                    udid: cString(result.device_udid),
                    pairingFilePath: cString(result.pairing_file_path)))
            } else {
                let message = cString(result.error)
                outcome = .failed(message.isEmpty ? "Pairing failed (code \(rc))" : message)
            }
            stikpair_result_free(&result)
            if let ctx = ctx { Unmanaged<PairingController>.fromOpaque(ctx).release() }

            DispatchQueue.main.async {
                self.stopAdvertising()
                self.pairingStarted = false
                self.phase = outcome
                if case .success = outcome {
                    self.bgTask?.progress.completedUnitCount = 100
                    self.postReturnNotification()
                }
                self.finishTask(success: rc == 0)
            }
        }
    }

    private func finishTask(success: Bool) {
        guard !taskFinished else { return }
        taskFinished = true
        bgTask?.setTaskCompleted(success: success)
        bgTask = nil
    }

    // MARK: - Callback handlers (main thread)

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    fileprivate func presentPin(_ pin: String) {
        phase = .showPin(pin)
        bgTask?.progress.completedUnitCount = 50
        bgTask?.updateTitle("StikPair", subtitle: "Enter code \(pin) on this device")
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    // MARK: - Notifications

    private func postReturnNotification() {
        notify(id: "stikpair.done",
               title: "Pairing complete",
               body: "Return to StikPair to export the pairing file.")
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func pairingFilePath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rp_pairing_file.plist").path
    }
}

// MARK: - C callbacks

private let readyCallback: StikPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }

    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pinCallback: StikPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}
