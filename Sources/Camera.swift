import AVFoundation
import Combine
import CoreImage
import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

struct DocumentCameraDeviceInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let isExternal: Bool
}

@MainActor
final class DocumentCameraController: ObservableObject {
    let session: AVCaptureSession
    @Published private(set) var devices: [DocumentCameraDeviceInfo] = []
    @Published private(set) var selectedID = ""
    @Published private(set) var status = ""
    @Published private(set) var error = ""
    @Published private(set) var running = false
    @Published private(set) var capturing = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var frameSize: CGSize?
    var resolutionLabel: String {
        guard let frameSize else { return "" }
        return "\(Int(frameSize.width)) × \(Int(frameSize.height))"
    }
    @Published private(set) var focusSupported = false
    @Published private(set) var focusEnabled = false
    @Published private(set) var focusChanging = false

    private let worker: DocumentCameraWorker
    private let preferences: UserDefaults
    private let authorizationStatus: () -> AVAuthorizationStatus
    private let requestAccess: @MainActor () async -> Bool
    private var permissionRequest: Task<Bool, Never>?
    private let rememberedKey = "documentCamera.lastDeviceID"
    private let focusKey = "documentCamera.continuousFocus"
    private var desiredFocus: Bool { preferences.object(forKey: focusKey) as? Bool ?? true }
    private var isOpen = false
    private var authorized = false
    private var isSuspended = false
    private var revision = UUID()
    private var captureRequest: DocumentCameraRequest?
    private var selectionRequest: DocumentCameraRequest?
    private var subscriptions = Set<AnyCancellable>()
    private var sessionSubscriptions = Set<AnyCancellable>()

    init(
        preferences: UserDefaults = .standard,
        authorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
        requestAccess: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }
    ) {
        let worker = DocumentCameraWorker()
        self.worker = worker
        self.session = worker.session
        self.preferences = preferences
        self.authorizationStatus = authorizationStatus
        self.requestAccess = requestAccess

        for event in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.publisher(for: event).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &subscriptions)
        }
    }

    func open() async {
        guard !isOpen || permissionDenied else { return }
        isOpen = true
        permissionDenied = false
        error = ""
        let openingRevision = revision
        status = "正在检查摄像头权限…"
        let granted: Bool
        switch authorizationStatus() {
        case .authorized:
            granted = true
        case .notDetermined:
            if let permissionRequest {
                granted = await permissionRequest.value
            } else {
                let requestAccess = self.requestAccess
                let request = Task { @MainActor in await requestAccess() }
                permissionRequest = request
                granted = await request.value
                permissionRequest = nil
            }
        default:
            granted = false
        }
        guard isOpen, revision == openingRevision else { return }
        guard !Task.isCancelled else {
            close()
            return
        }
        authorized = granted
        permissionDenied = !granted
        guard granted else {
            status = "未获得摄像头权限"
            error = "请在系统设置的「隐私与安全性」→「摄像头」中允许访问，再重新检查权限。"
            return
        }

        refresh()
        if selectedID.isEmpty,
           let preferred = DocumentCameraPolicy.preferredExternal(in: devices, rememberedID: preferences.string(forKey: rememberedKey)) {
            selectDevice(preferred.id)
        }
    }

    func refresh() {
        guard isOpen, authorized else { return }
        devices = DocumentCameraWorker.availableDevices().map { device in
            DocumentCameraDeviceInfo(id: device.uniqueID, name: device.localizedName, isExternal: device.deviceType == .external)
        }.sorted { lhs, rhs in
            if lhs.isExternal != rhs.isExternal { return lhs.isExternal }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        if !selectedID.isEmpty, !devices.contains(where: { $0.id == selectedID }) {
            stopSelection()
            status = "摄像头已断开"
            error = "请重新连接高拍仪，然后选择设备。"
        } else if selectedID.isEmpty && error.isEmpty {
            status = devices.isEmpty ? "未发现摄像头" : "请选择摄像头"
        }
    }

    func selectDevice(_ id: String) {
        guard isOpen, authorized, let device = devices.first(where: { $0.id == id }) else { return }
        if selectedID == id, selectionRequest != nil { return }
        stopSelection()
        selectedID = id
        error = ""
        guard !isSuspended else {
            status = "摄像头已暂停"
            return
        }
        status = "正在启动摄像头…"
        let selectionRevision = revision
        let request = DocumentCameraRequest()
        selectionRequest = request
        worker.start(id: id, request: request, wantsFocus: desiredFocus) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, self.revision == selectionRevision else { return }
                switch result {
                case .success(let config):
                    self.running = true
                    self.frameSize = config.frameSize
                    self.focusSupported = config.focusSupported
                    self.focusEnabled = config.focusEnabled
                    self.status = "摄像头已就绪"
                    self.observeSessionEvents(for: selectionRevision)
                    self.preferences.set(device.id, forKey: self.rememberedKey)
                case .failure(let failure):
                    self.selectionRequest = nil
                    self.sessionSubscriptions.removeAll()
                    self.selectedID = ""
                    self.status = "无法打开摄像头"
                    self.error = failure.message
                }
            }
        }
    }

    func suspend() {
        guard isOpen, !isSuspended else { return }
        isSuspended = true
        let id = selectedID
        if !id.isEmpty {
            stopSelection()
            selectedID = id
            status = "摄像头已暂停"
        }
    }

    func resume() {
        guard isOpen, isSuspended else { return }
        isSuspended = false
        refresh()
        if !selectedID.isEmpty {
            selectDevice(selectedID)
        }
    }

    func close() {
        isOpen = false
        authorized = false
        isSuspended = false
        stopSelection()
        devices = []
        status = ""
        error = ""
        permissionDenied = false
    }

    func setFocus(_ enabled: Bool) {
        guard running, focusSupported, !capturing, !focusChanging else { return }
        focusChanging = true
        let focusRevision = revision
        worker.setFocus(enabled) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, self.revision == focusRevision else { return }
                self.focusChanging = false
                switch result {
                case .success:
                    self.focusEnabled = enabled
                    self.preferences.set(enabled, forKey: self.focusKey)
                    self.error = ""
                case .failure(let failure): self.error = failure.message
                }
            }
        }
    }

    func setBatch(_ enabled: Bool, onReady: @escaping @Sendable () -> Void) { worker.setBatch(enabled, onReady: onReady) }

    func capture() async -> HomeworkPhoto? {
        guard isOpen, running, !capturing, !Task.isCancelled else { return nil }
        let request = DocumentCameraRequest()
        captureRequest = request
        capturing = true
        error = ""
        let worker = self.worker
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.capture(request: request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            request.cancel()
            worker.cancelCapture(id: request.id)
        }

        guard captureRequest === request else { return nil }
        captureRequest = nil
        capturing = false
        guard !Task.isCancelled, let result else { return nil }
        switch result {
        case .success(let photo):
            return photo
        case .failure(let failure):
            error = failure.message
            return nil
        }
    }

    private func stopSelection() {
        revision = UUID()
        sessionSubscriptions.removeAll()
        selectionRequest?.cancel()
        selectionRequest = nil
        captureRequest?.cancel()
        captureRequest = nil
        selectedID = ""
        running = false
        capturing = false
        frameSize = nil
        focusSupported = false
        focusEnabled = false
        focusChanging = false
        worker.stop()
    }

    private func observeSessionEvents(for selectionRevision: UUID) {
        for event in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            NotificationCenter.default.publisher(for: event, object: session).sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isOpen, self.revision == selectionRevision else { return }
                    self.stopSelection()
                    self.status = "摄像头已停止"
                    self.error = "摄像头连接中断，请检查连接后重新选择设备。"
                }
            }.store(in: &sessionSubscriptions)
        }
    }
}

enum DocumentCameraPolicy {
    static func preferredExternal(in devices: [DocumentCameraDeviceInfo], rememberedID: String?) -> DocumentCameraDeviceInfo? {
        devices.first { $0.isExternal && $0.id == rememberedID } ?? devices.first { $0.isExternal }
    }

    static func acceptsDimensions(_ size: CMVideoDimensions) -> Bool {
        size.width > 0 && size.height > 0 && Int64(size.width) * Int64(size.height) <= 12_000_000
    }

    static func preferredFormatIndex(dimensions: [CMVideoDimensions]) -> Int? {
        var best: (index: Int, pixels: Int64)?
        for (index, size) in dimensions.enumerated() where acceptsDimensions(size) {
            let pixels = Int64(size.width) * Int64(size.height)
            guard pixels > (best?.pixels ?? 0) else { continue }
            best = (index, pixels)
        }
        return best?.index
    }

    static func preferredFrameDuration(ranges: [(min: CMTime, max: CMTime)]) -> CMTime? {
        let ranges = ranges.filter { $0.min.isNumeric && $0.max.isNumeric && $0.min > .zero && $0.max >= $0.min }
        let target = CMTime(value: 1, timescale: 15)
        if ranges.contains(where: { $0.min <= target && target <= $0.max }) {
            return target
        }
        let slower = ranges.map(\.min).filter { $0 > target }.min()
        return slower ?? ranges.map(\.max).max()
    }

    static func preferredPixelFormat(available: [OSType]) -> OSType? {
        [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8,
         kCVPixelFormatType_422YpCbCr8_yuvs,
         kCVPixelFormatType_32BGRA].first { available.contains($0) }
    }
}

private final class DocumentCameraRequest: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private struct DocumentCameraFailure: Error, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// All capture session configuration and pending-frame state are confined to captureQueue.
private final class DocumentCameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias CaptureResult = Result<HomeworkPhoto, DocumentCameraFailure>
    typealias CaptureCompletion = @Sendable (CaptureResult?) -> Void

    let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "zhiwei.document-camera.capture", qos: .userInitiated)
    private let encodingQueue = DispatchQueue(label: "zhiwei.document-camera.encode", qos: .userInitiated)
    private var pending: PendingCapture?
    private var configuredOutput: AVCaptureVideoDataOutput?
    private var expectedDimensions: CMVideoDimensions?
    private var focusDevice: AVCaptureDevice?
    private var focusEnabled = false
    private var batchEnabled = false
    private var onReady: (@Sendable () -> Void)?
    private var lastAnalysis = CFAbsoluteTimeGetCurrent()
    private var prior: [UInt8]?
    private var stable = 0
    private var absent = 0
    private var armed = true
    func setBatch(_ enabled: Bool, onReady: @escaping @Sendable () -> Void) {
        captureQueue.async { self.batchEnabled = enabled; self.onReady = onReady; self.prior = nil; self.stable = 0; self.absent = 0; self.armed = true }
    }
    private func analyze(_ pixels: CVPixelBuffer) {
        guard batchEnabled, CFAbsoluteTimeGetCurrent() - lastAnalysis > 0.45 else { return }
        lastAnalysis = CFAbsoluteTimeGetCurrent()
        let source = CIImage(cvPixelBuffer: pixels)
        let scale = CGAffineTransform(scaleX: 96/source.extent.width, y: 96/source.extent.height)
        let small = source.transformed(by: scale)
        guard let cg = Self.imageContext.createCGImage(small, from: CGRect(x:0,y:0,width:96,height:96)) else {return}
        var bytes = [UInt8](repeating: 0, count: 96*96)
        guard let ctx = CGContext(data: &bytes, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {return}
        ctx.draw(cg, in: CGRect(x:0,y:0,width:96,height:96))
        var diff = 255.0
        if let prior { var sum = 0; for i in bytes.indices { sum += abs(Int(prior[i]) - Int(bytes[i])) }; diff = Double(sum) / Double(bytes.count) }
        prior = bytes
        stable = diff < 2.5 ? stable + 1 : 0
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.5; request.minimumSize = 0.25; request.maximumObservations = 1
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let found = !(request.results ?? []).isEmpty
        if !found { absent += 1; if absent >= 2 { armed = true }; stable = 0; return }
        absent = 0
        if armed && stable >= 3 && pending == nil { armed = false; stable = 0; onReady?() }
    }

    private struct PendingCapture {
        let id: UUID
        let completion: CaptureCompletion
        var frameReceived = false
        var waitForFocus = false
        var focusStableSince: TimeInterval?
    }

    // The sample buffer's image is retained only for an explicitly requested capture.
    private struct CapturedFrame: @unchecked Sendable {
        let pixels: CVPixelBuffer
    }

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    struct StartInfo: Sendable { let frameSize: CGSize; let focusSupported: Bool; let focusEnabled: Bool }
    func start(id: String, request: DocumentCameraRequest, wantsFocus: Bool, completion: @escaping @Sendable (Result<StartInfo, DocumentCameraFailure>) -> Void) {
        captureQueue.async {
            guard !request.isCancelled else { return }
            self.stopOnQueue()
            do {
                let device = try self.configure(id: id)
                guard !request.isCancelled else {
                    self.stopOnQueue()
                    return
                }
                let configuredSize = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                guard DocumentCameraPolicy.acceptsDimensions(configuredSize) else {
                    throw DocumentCameraFailure("摄像头没有可用的 1200 万像素以内视频模式。")
                }
                self.session.startRunning()
                guard !request.isCancelled else {
                    self.stopOnQueue()
                    return
                }
                guard self.session.isRunning else {
                    throw DocumentCameraFailure("无法启动摄像头，请检查连接或关闭其他正在使用摄像头的应用。")
                }
                let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                guard DocumentCameraPolicy.acceptsDimensions(size) else {
                    throw DocumentCameraFailure("摄像头切换到了超出 1200 万像素的模式，请尝试其他设备。")
                }
                if let expected=self.expectedDimensions, size.width != expected.width || size.height != expected.height {
                    throw DocumentCameraFailure("设备实际模式为 \(size.width) × \(size.height)，未保持选定的 \(expected.width) × \(expected.height)，请暂停其他相机预览后刷新重试。")
                }
                let supported = device.isFocusModeSupported(.continuousAutoFocus)
                self.focusDevice = device
                self.focusEnabled = false
                if supported {
                    try self.applyFocus(wantsFocus, device: device)
                    self.focusEnabled = wantsFocus
                }
                completion(.success(StartInfo(frameSize: CGSize(width: Int(size.width), height: Int(size.height)),
                                             focusSupported: supported, focusEnabled: self.focusEnabled)))
            } catch {
                self.stopOnQueue()
                let failure = error as? DocumentCameraFailure ?? DocumentCameraFailure("摄像头暂时无法使用，请检查连接并重试。")
                completion(.failure(failure))
            }
        }
    }

    func stop() {
        captureQueue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        if let pending {
            finishCapture(id: pending.id, result: nil)
        }
        if session.isRunning { session.stopRunning() }
        guard !session.inputs.isEmpty || !session.outputs.isEmpty else { return }
        configuredOutput?.setSampleBufferDelegate(nil, queue: nil)
        configuredOutput = nil
        expectedDimensions = nil
        focusDevice = nil
        focusEnabled = false
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }

    private func configure(id: String) throws -> AVCaptureDevice {
        guard let device = Self.availableDevices().first(where: { $0.uniqueID == id }) else {
            throw DocumentCameraFailure("摄像头已断开，请重新连接。")
        }
        let modes = device.formats.compactMap { format -> (format: AVCaptureDevice.Format, duration: CMTime)? in
            let ranges = format.videoSupportedFrameRateRanges.map { (min: $0.minFrameDuration, max: $0.maxFrameDuration) }
            guard let duration = DocumentCameraPolicy.preferredFrameDuration(ranges: ranges) else { return nil }
            return (format, duration)
        }
        let dimensions = modes.map { CMVideoFormatDescriptionGetDimensions($0.format.formatDescription) }
        guard let index = DocumentCameraPolicy.preferredFormatIndex(dimensions: dimensions) else {
            throw DocumentCameraFailure("摄像头没有可用的 1200 万像素以内视频模式。")
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        do {
            defer { session.commitConfiguration() }
            try configure(input: input, output: output, format: modes[index].format, duration: modes[index].duration)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let chosenSize=CMVideoFormatDescriptionGetDimensions(modes[index].format.formatDescription)
        if let pixelFormat = DocumentCameraPolicy.preferredPixelFormat(available: output.availableVideoPixelFormatTypes) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: Int(chosenSize.width),
                kCVPixelBufferHeightKey as String: Int(chosenSize.height)]
        } else {
            // AVFoundation supplies an uncompressed pixel format for this device.
            output.videoSettings = nil
        }
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        output.setSampleBufferDelegate(self, queue: captureQueue)
        return device
    }

    private func configure(
        input: AVCaptureDeviceInput,
        output: AVCaptureVideoDataOutput,
        format: AVCaptureDevice.Format,
        duration: CMTime
    ) throws {
        guard session.canAddInput(input) else {
            throw DocumentCameraFailure("无法连接这台摄像头。")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw DocumentCameraFailure("这台摄像头暂时无法提供视频画面。")
        }
        session.addOutput(output)
        configuredOutput = output

        // macOS does not support .inputPriority. Its default .high preset can
        // renegotiate a manually selected 4K format back to 1080p at commit.
        let dimensions=CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        if dimensions.width==3840 && dimensions.height==2160,
           session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        expectedDimensions=dimensions

        let device = input.device
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func applyFocus(_ enabled: Bool, device: AVCaptureDevice) throws {
        let mode: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
        guard device.isFocusModeSupported(mode) else {
            throw DocumentCameraFailure(enabled ? "此摄像头不支持连续自动对焦。" : "此摄像头不支持锁定对焦，无法关闭连续自动对焦。")
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.focusMode = mode
        } catch { throw DocumentCameraFailure("无法调整对焦设置，请检查摄像头连接。") }
    }

    func setFocus(_ enabled: Bool, completion: @escaping @Sendable (Result<Void, DocumentCameraFailure>) -> Void) {
        captureQueue.async {
            guard let device = self.focusDevice, self.session.isRunning else {
                completion(.failure(DocumentCameraFailure("摄像头未就绪，无法调整对焦。"))); return
            }
            do {
                try self.applyFocus(enabled, device: device)
                self.focusEnabled = enabled
                completion(.success(()))
            } catch { completion(.failure(error as? DocumentCameraFailure ?? DocumentCameraFailure("无法调整对焦设置。"))) }
        }
    }

    func capture(request: DocumentCameraRequest, completion: @escaping CaptureCompletion) {
        captureQueue.async {
            guard !request.isCancelled else {
                completion(nil)
                return
            }
            let id = request.id
            guard self.session.isRunning, self.pending == nil else {
                completion(.failure(DocumentCameraFailure("摄像头还未就绪，请稍后重试。")))
                return
            }
            self.pending = PendingCapture(id: id, completion: completion, waitForFocus: self.focusEnabled)
            let waitingForFocus = self.focusEnabled
            self.captureQueue.asyncAfter(deadline: .now() + .seconds(waitingForFocus ? 8 : 4)) { [weak self] in
                self?.finishCapture(id: id, result: .failure(DocumentCameraFailure(waitingForFocus ? "等待对焦稳定超时，未拍照；请检查光线和摄像头后重试。" : "拍摄超时，请重试。")))
            }
        }
    }

    func cancelCapture(id: UUID) {
        captureQueue.async { self.finishCapture(id: id, result: nil) }
    }

    private func finishCapture(id: UUID, result: CaptureResult?) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        request.completion(result)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === configuredOutput, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if pending == nil { analyze(pixels) }
        guard let request = pending, !request.frameReceived else { return }
        if request.waitForFocus {
            guard let device = focusDevice, focusEnabled, device.focusMode == .continuousAutoFocus else {
                finishCapture(id: request.id, result: .failure(DocumentCameraFailure("自动对焦已停止，未拍照；请重新开启后重试。")))
                return
            }
            if device.isAdjustingFocus { pending?.focusStableSince = nil; return }
            let now = ProcessInfo.processInfo.systemUptime
            guard let stableSince = request.focusStableSince else { pending?.focusStableSince = now; return }
            guard now - stableSince >= 1.0 else { return }
        }
        if let expectedDimensions,
           CVPixelBufferGetWidth(pixels) != Int(expectedDimensions.width) || CVPixelBufferGetHeight(pixels) != Int(expectedDimensions.height) {
            finishCapture(id:request.id,result:.failure(DocumentCameraFailure("摄像头输出为 \(CVPixelBufferGetWidth(pixels)) × \(CVPixelBufferGetHeight(pixels))，未达到选定的 \(expectedDimensions.width) × \(expectedDimensions.height)。请刷新设备后重试。")))
            return
        }
        pending?.frameReceived = true
        let frame = CapturedFrame(pixels: pixels)
        let id = request.id
        encodingQueue.async {
            let result = autoreleasepool { Self.encode(frame) }
            self.captureQueue.async { self.finishCapture(id: id, result: result) }
        }
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    private static func encode(_ frame: CapturedFrame) -> CaptureResult {
        let source = CIImage(cvPixelBuffer: frame.pixels)
        let longest = max(source.extent.width, source.extent.height)
        guard longest.isFinite, longest > 0 else {
            return .failure(DocumentCameraFailure("无法读取摄像头画面，请重新拍摄。"))
        }
        guard let image = imageContext.createCGImage(source, from: source.extent) else {
            return .failure(DocumentCameraFailure("照片处理失败，请重新拍摄。"))
        }
        do {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw DocumentCameraFailure("无法生成照片") }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw DocumentCameraFailure("无法生成照片") }
            return .success(HomeworkPhoto(jpegData: data as Data))
        } catch {
            return .failure(DocumentCameraFailure(error.localizedDescription))
        }
    }
}

struct HomeworkPhoto: Sendable { let jpegData: Data }
