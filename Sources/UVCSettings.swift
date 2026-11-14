import Foundation
import Combine

struct UVCControl: Decodable {
    let name: String
    let min: Int
    let max: Int
    let step: Int
    let value: Int
    let writable: Bool
}
private struct UVCCapabilities: Decodable { let controls: [UVCControl] }
private struct UVCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class UVCSettings: ObservableObject {
    @Published private(set) var controls: [String: UVCControl] = [:]
    @Published var values: [String: Double] = [:]
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    private var cameraID = ""
    private var generation = UUID()
    private let queue = DispatchQueue(label: "scanassistant.uvc", qos: .userInitiated)
    private let names = ["brightness", "contrast", "sharpness", "white_balance_temperature_auto", "white_balance_temperature"]
    var hasControls: Bool { !controls.isEmpty }
    var whiteBalanceAuto: Bool { (values["white_balance_temperature_auto"] ?? 0) != 0 }
    var dirty: Bool { controls.values.contains { item in values[item.name].map { Int($0.rounded()) != item.value } ?? false } }

    func reset() {
        generation = UUID(); cameraID = ""; controls = [:]; values = [:]; loading = false; message = ""
    }
    func load(_ selectedID: String) {
        reset()
        let hex = selectedID.lowercased().hasPrefix("0x") ? String(selectedID.dropFirst(2)) : ""
        guard hex.count >= 8, hex.allSatisfy({ $0.isHexDigit }) else {
            message = "当前摄像头不能通过 USB 控制调节。"; return
        }
        let suffix = String(hex.suffix(8))
        cameraID = String(suffix.prefix(4)) + ":" + String(suffix.suffix(4))
        let id = cameraID, token = generation
        loading = true; message = "正在读取摄像头设置…"
        queue.async { [weak self] in
            let result = Result { try Self.read(id) }
            DispatchQueue.main.async { [weak self] in self?.finishLoad(result, token: token) }
        }
    }
    private func finishLoad(_ result: Result<[UVCControl], Error>, token: UUID) {
        guard generation == token else { return }
        loading = false
        switch result {
        case .success(let all):
            let chosen = all.filter { names.contains($0.name) && $0.min <= $0.max && $0.value >= $0.min && $0.value <= $0.max }
            controls = Dictionary(uniqueKeysWithValues: chosen.map { ($0.name, $0) })
            values = Dictionary(uniqueKeysWithValues: chosen.map { ($0.name, Double($0.value)) })
            message = chosen.isEmpty ? "当前摄像头没有可调的 UVC 图像设置。" : "已读取摄像头当前设置。"
        case .failure(let error): controls = [:]; values = [:]; message = "无法读取摄像头设置：\(error.localizedDescription)"
        }
    }
    func apply() {
        guard !loading, !cameraID.isEmpty else { return }
        let id = cameraID, token = generation, original = controls, desired = values
        let autoOn = (desired["white_balance_temperature_auto"] ?? 0) != 0
        let order = ["white_balance_temperature_auto", "brightness", "contrast", "sharpness", "white_balance_temperature"]
        let changes: [(String, Int)] = order.compactMap { name in
            guard let item = original[name], item.writable, let v = desired[name], v.isFinite else { return nil }
            if name == "white_balance_temperature" && autoOn { return nil }
            let rounded = Int(v.rounded())
            guard rounded >= item.min && rounded <= item.max && rounded != item.value else { return nil }
            return (name, rounded)
        }
        guard !changes.isEmpty else { message = "没有需要应用的变化。"; return }
        loading = true; message = "正在应用并核对摄像头设置…"
        queue.async { [weak self] in
            var problem: String?
            for (name, value) in changes {
                do { _ = try Self.execute(["set", name, String(value), "-d", id]) }
                catch { problem = "部分设置未应用：\(error.localizedDescription)"; break }
            }
            let result = Result { try Self.read(id) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.finishLoad(result, token:token)
                if let problem { self.message = problem + "。已重新读取设备。" }
                else if case .success = result { self.message = "设置已应用并从设备读回。" }
            }
        }
    }
    private nonisolated static func read(_ id: String) throws -> [UVCControl] {
        let data = try execute(["caps", "-d", id])
        return try JSONDecoder().decode(UVCCapabilities.self, from:data).controls
    }
    private nonisolated static func execute(_ args: [String]) throws -> Data {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("uvcctl"), FileManager.default.isExecutableFile(atPath: executable.path) else { throw UVCError(message:"控制工具不可用") }
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable; process.arguments = args; process.standardOutput = out; process.standardError = err
        let done = DispatchSemaphore(value:0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout:.now()+20) == .timedOut {
            process.terminate()
            if done.wait(timeout:.now()+2) == .timedOut { kill(process.processIdentifier,SIGKILL); process.waitUntilExit() }
            throw UVCError(message:"连接摄像头超时")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let details = String(data:stderr, encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw UVCError(message: details.isEmpty ? "设备拒绝访问" : details)
        }
        return data
    }
}
