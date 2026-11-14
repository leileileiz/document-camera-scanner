import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import ImageIO

@main struct ScanApp: App {
    var body: some Scene {
        WindowGroup { MainView() }
            .windowStyle(.titleBar)
            .defaultSize(width: 1120, height: 800)
    }
}

struct MainView: View {
    @StateObject private var camera = DocumentCameraController()
    @StateObject private var uvc = UVCSettings()
    @State private var imageSettingsOpen = false
    @State private var flatField: FlatFieldReference?
    @State private var flatEnabled = UserDefaults.standard.object(forKey:"scan.flatEnabled") as? Bool ?? true
    @State private var folder: URL?
    @State private var mode = 0
    @State private var seconds = 5
    @State private var remaining = 5
    @State private var active = false
    @State private var busy = false
    @State private var message = "选择保存文件夹，然后拍照"
    @State private var rotation = 0
    @State private var crop = true
    @AppStorage("scan.cropAlgorithm") private var cropAlgorithm = CropAlgorithm.automatic
    @AppStorage("scan.manualCrop") private var manualCrop = ManualCrop.initial
    @State private var freehandSelection: FreehandSelection?
    @AppStorage("scan.lockManualCropToA4") private var lockManualCropToA4 = false
    @AppStorage("scan.manualCropA4Orientation") private var manualCropA4Orientation = A4CropOrientation.portrait
    @AppStorage("scan.textDeskew") private var deskew = true
    @AppStorage("scan.enhancement") private var enhancement = "homework"
    @AppStorage("scan.copyAfterCapture") private var copyAfterCapture = false
    @State private var tonePreview: TonePreview?
    @State private var tonePreviewError = ""

    private struct TonePreview: Identifiable {
        let id = UUID()
        let image: NSImage
        let message: String
    }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var usesManualCrop: Bool { crop && cropAlgorithm == .manual }
    private var usesFreehand: Bool { crop && cropAlgorithm == .freehand }
    private var selectionReady: Bool { !usesFreehand || freehandSelection != nil }
    private var displayedFrameSize: CGSize? {
        guard let size = camera.frameSize else { return nil }
        return rotation % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
    private var manualCropAspectRatio: CGFloat? {
        lockManualCropToA4 ? manualCropA4Orientation.aspectRatio : nil
    }
    private func fitManualCrop(_ selection: ManualCrop) -> ManualCrop {
        guard let aspectRatio = manualCropAspectRatio, let size = displayedFrameSize else { return selection }
        return selection.fitted(to: aspectRatio, in: size)
    }
    private var displayedManualCrop: Binding<ManualCrop> {
        Binding(get: { fitManualCrop(manualCrop) }, set: { manualCrop = $0 })
    }
    var body: some View {
        HStack(spacing: 0) {
            preview
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls.frame(width: 322)
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { rotation = UserDefaults.standard.integer(forKey: "rotation"); restoreFolder(); await camera.open() }
        .onDisappear { stop(); camera.close() }
        .onChange(of: camera.running) { _, running in
            if running { uvc.load(camera.selectedID); flatField = FlatFieldReference.load(deviceID:camera.selectedID) }
            else { stop(); uvc.reset(); flatField = nil }
        }
        .onReceive(timer) { _ in
            guard active, mode == 2, !busy else { return }
            remaining -= 1
            if remaining <= 0 { take() }
        }
        .sheet(item: $tonePreview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .accessibilityLabel("自动亮度与对比度预览")
                HStack {
                    Text(preview.message).foregroundStyle(.secondary)
                    Spacer()
                    Button("关闭") { tonePreview = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(16).frame(width: 640, height: 520)
        }
        .alert("无法预览", isPresented: Binding(get: { !tonePreviewError.isEmpty }, set: {
            if !$0 { tonePreviewError = "" }
        })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(tonePreviewError)
        }
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                CameraPreview(session: camera.session)
                    .frame(width: rotation % 2 == 0 ? geo.size.width : geo.size.height,
                           height: rotation % 2 == 0 ? geo.size.height : geo.size.width)
                    .rotationEffect(.degrees(Double(rotation) * 90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                if (usesManualCrop || usesFreehand), camera.running, let size = displayedFrameSize {
                    let picture = AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: geo.size))
                    if picture.width > 0, picture.height > 0 {
                        Group {
                            if usesFreehand {
                                FreehandSelectionOverlay(selection: $freehandSelection, size: picture.size,
                                                         editable: !active && !busy)
                            } else {
                                ManualCropOverlay(selection: displayedManualCrop, size: picture.size,
                                                  editable: !active && !busy, aspectRatio: manualCropAspectRatio)
                            }
                        }
                            .position(x: picture.midX, y: picture.midY)
                    }
                }
                if !camera.running {
                    Text(camera.status.isEmpty ? "正在准备摄像头…" : camera.status)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if active && mode == 2 {
                Text("\(remaining) 秒")
                    .font(.title.bold())
                    .padding(12)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    cameraSettings
                    Divider()
                    cropSettings
                    Divider()
                    folderSettings
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            captureControls.padding(16)
        }
    }

    private var cameraSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("设备", selection: Binding(get: { camera.selectedID }, set: { stop(); camera.selectDevice($0) })) {
                Text("选择摄像头").tag("")
                ForEach(camera.devices) { Text($0.name).tag($0.id) }
            }.disabled(uvc.loading || busy || active)
            HStack {
                Text(camera.resolutionLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { camera.refresh() }.disabled(active || busy)
                Button("旋转") {
                    manualCrop = manualCrop.rotatedRight
                    freehandSelection = freehandSelection?.rotatedRight
                    rotation = (rotation + 1) % 4
                    UserDefaults.standard.set(rotation, forKey: "rotation")
                }.disabled(active || busy)
            }
            Toggle("连续自动对焦", isOn: Binding(get: { camera.focusEnabled }, set: { camera.setFocus($0) }))
                .disabled(!camera.running || !camera.focusSupported || camera.focusChanging || active || busy)
                .help(!camera.focusSupported ? "当前设备不支持" : camera.focusEnabled ? "拍摄前等待对焦稳定" : "对焦已锁定")
            DisclosureGroup("摄像头画面设置", isExpanded: $imageSettingsOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    uvcSlider("亮度", key: "brightness")
                    uvcSlider("对比度", key: "contrast")
                    uvcSlider("锐度", key: "sharpness")
                    if let auto = uvc.controls["white_balance_temperature_auto"] {
                        Toggle("自动白平衡", isOn: Binding(get: { uvc.whiteBalanceAuto }, set: {
                            uvc.values["white_balance_temperature_auto"] = $0 ? 1 : 0
                        })).disabled(!auto.writable || uvc.loading || busy || active)
                    }
                    uvcSlider("白平衡", key: "white_balance_temperature", disabled: uvc.whiteBalanceAuto, unit: " K")
                    HStack {
                        Button("读取当前值") { uvc.load(camera.selectedID) }
                            .disabled(!camera.running || uvc.loading || busy || active)
                        Button("应用设置") { uvc.apply() }
                            .disabled(!camera.running || !uvc.dirty || uvc.loading || busy || active)
                    }
                    Text(uvc.message).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }

    private var cropSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("裁边", isOn: $crop).disabled(active || busy)
            Picker("裁边算法", selection: $cropAlgorithm) {
                ForEach(CropAlgorithm.allCases) { algorithm in
                    Text(algorithm.title).tag(algorithm)
                }
            }.disabled(!crop || active || busy)
                .help("自动模式先用 Vision，找不到四角时再用纸张外轮廓")
            if usesManualCrop {
                HStack {
                    Toggle("锁定 A4 比例", isOn: Binding(
                        get: { lockManualCropToA4 },
                        set: { locked in
                            if !locked { manualCrop = fitManualCrop(manualCrop) }
                            lockManualCropToA4 = locked
                        }))
                    Spacer()
                    Button("重置框") { manualCrop = .initial }
                }.disabled(active || busy)
                if lockManualCropToA4 {
                    Picker("A4 方向", selection: $manualCropA4Orientation) {
                        ForEach(A4CropOrientation.allCases) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }.pickerStyle(.segmented).disabled(active || busy)
                }
            } else if usesFreehand {
                HStack {
                    Text("按住鼠标画一圈，松开后自动闭合")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除圈选") { freehandSelection = nil }
                        .disabled(freehandSelection == nil || active || busy)
                }
            } else {
                Toggle("文字行纠偏", isOn: $deskew).disabled(!crop || active || busy)
                    .help("在裁边和透视校正后，自动校正可可靠识别的轻微文字行倾斜")
            }
            Picker("图片增强", selection: $enhancement) {
                Text("不增强").tag("none")
                Text("作业增强").tag("homework")
                Text("自动亮度／对比度").tag("autoPaper")
                Text("黑白扫描").tag("scan")
            }.disabled(active || busy)
            if enhancement == "autoPaper" {
                HStack {
                    Text("提亮纸面，保留浅色笔迹").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("试看效果") { take(previewOnly: true) }
                        .disabled(!cameraReady || !selectionReady || active || busy)
                        .help("拍一张预览图，供查看处理效果")
                }
            }
            HStack {
                Toggle("A4 光照补偿", isOn: $flatEnabled)
                    .disabled(flatField == nil || busy || active)
                    .onChange(of: flatEnabled) { _, value in UserDefaults.standard.set(value, forKey: "scan.flatEnabled") }
                Spacer()
                Button("白纸校准…") { calibrate() }
                    .disabled(!camera.running || camera.focusChanging || uvc.loading || busy || active)
                    .help(flatField == nil ? "尚未校准当前摄像头" : "灯光或摄像头设置变化后请重新校准")
            }
        }
    }

    private var folderSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("选择保存文件夹…") { chooseFolder() }.disabled(active || busy)
                Spacer()
                if let folder {
                    Button("打开文件夹") { NSWorkspace.shared.open(folder) }
                }
            }
            Text(folder?.path ?? "尚未选择文件夹")
                .font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                .help(folder?.path ?? "")
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("拍摄方式", selection: $mode) {
                Text("手动拍照").tag(0)
                Text("自动检测文件").tag(1)
                Text("倒计时连拍").tag(2)
            }.pickerStyle(.segmented).labelsHidden().disabled(active || busy)
            if mode == 2 {
                Stepper("间隔 \(seconds) 秒", value: $seconds, in: 2...120).disabled(active)
            } else if mode == 1 {
                Text("拍完后移走纸张，再放入下一张。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(camera.error.isEmpty ? message : camera.error)
                .font(.callout)
                .foregroundStyle(camera.error.isEmpty ? Color.secondary : Color.orange)
                .lineLimit(3)
            if mode == 0 {
                Button { take() } label: { Text("拍一张").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.space, modifiers: []).disabled(!canCapture || busy)
                Toggle("复制到剪贴板", isOn: $copyAfterCapture)
                    .disabled(busy)
            } else {
                Button { active ? stop() : start() } label: {
                    Text(active ? "停止" : "开始").frame(maxWidth: .infinity)
                }.disabled(!active && (!canCapture || busy))
            }
        }.buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    func uvcSlider(_ title: String, key: String, disabled: Bool = false, unit: String = "") -> some View {
        if let control = uvc.controls[key], control.max > control.min {
            HStack {
                Text(title).frame(width:56, alignment:.leading)
                Slider(value: Binding(get: { uvc.values[key] ?? Double(control.value) }, set: { uvc.values[key] = $0 }), in: Double(control.min)...Double(control.max), step: Double(max(1,control.step)))
                    .disabled(disabled || !control.writable || uvc.loading || busy || active)
                Text("\(Int((uvc.values[key] ?? Double(control.value)).rounded()))\(unit)")
                    .monospacedDigit().frame(width:unit.isEmpty ? 42:72,alignment:.trailing)
            }
        }
    }
    private var cameraReady: Bool { camera.running && !camera.focusChanging && !uvc.loading }
    var canCapture: Bool { cameraReady && selectionReady && folder != nil }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let chosen = panel.url {
            do {
                try FolderPreference().remember(chosen)
                folder = chosen; message = "照片将按 0001、0002 顺序保存"
            } catch {
                FolderPreference().clear(); folder = chosen; message = "已选择文件夹，但无法记住它；下次需要重新选择"
            }
        }
    }
    func restoreFolder() {
        switch FolderPreference().restore() {
        case .none: break
        case .unavailable: folder = nil; message = "上次的文件夹不可用，请重新选择"
        case .folder(let url): folder = url; message = "已恢复上次的保存文件夹"
        }
    }
    func calibrate() {
        guard camera.running, !busy else { return }
        let deviceID = camera.selectedID
        busy = true; message = "正在拍摄白纸校准图…"
        Task {
            guard let photo = await camera.capture() else { busy = false; message = "校准拍摄失败，请检查摄像头"; return }
            do {
                let ref = try await Task.detached(priority:.userInitiated) {
                    let ref = try FlatFieldReference.make(data:photo.jpegData,deviceID:deviceID)
                    try ref.save()
                    return ref
                }.value
                if camera.running && camera.selectedID == deviceID {
                    flatField = ref; flatEnabled = true; UserDefaults.standard.set(true,forKey:"scan.flatEnabled")
                    message = "白纸校准完成；光照补偿只作用于识别出的 A4 纸张。"
                }
            } catch { message = "校准未完成：\(error.localizedDescription)" }
            busy = false
        }
    }
    func start() {
        guard canCapture else { return }; active = true
        if mode == 1 {
            message = "等待纸张放稳…"
            camera.setBatch(true) { DispatchQueue.main.async { if active && mode == 1 && !busy { take() } } }
        } else { remaining = seconds; message = "倒计时连拍中" }
    }
    func stop() { active = false; camera.setBatch(false, onReady: {}); remaining = seconds }
    func take(previewOnly: Bool = false) {
        guard cameraReady, selectionReady, !busy, previewOnly ? !active : folder != nil else { return }
        let target = previewOnly ? nil : folder
        busy = true; message = camera.focusEnabled ? "正在等待对焦稳定…" : "正在拍摄和整理…"
        let selectedRotation = rotation, selectedCrop = crop, selectedEnhancement = enhancement
        let selectedFlat = flatEnabled ? flatField : nil
        let selectedDeskew = deskew
        let selectedCropAlgorithm = cropAlgorithm
        let selectedManualCrop = fitManualCrop(manualCrop)
        let selectedManualA4 = lockManualCropToA4
        let selectedFreehand = freehandSelection
        let shouldCopy = !previewOnly && mode == 0 && copyAfterCapture
        Task {
            guard let photo = await camera.capture() else { busy = false; stop(); message = "拍照失败，请检查摄像头后重试"; return }
            let processPhoto: @Sendable () throws -> ScanProcessing.Result = {
                try ScanProcessing.process(photo.jpegData, rotation: selectedRotation,
                    crop: selectedCrop, enhancement: selectedEnhancement, flatField: selectedFlat,
                    deskew: selectedDeskew, cropAlgorithm: selectedCropAlgorithm,
                    manualCrop: selectedManualCrop, manualA4: selectedManualA4,
                    freehandSelection: selectedFreehand)
            }
            guard let target else {
                do {
                    let result = try await Task.detached(priority: .userInitiated, operation: processPhoto).value
                    guard let image = NSImage(data: result.data) else { throw ScanProcessing.failure("无法读取预览图") }
                    tonePreview = TonePreview(image: image, message: result.message)
                    message = "预览完成"
                } catch {
                    tonePreviewError = error.localizedDescription
                    message = "预览失败"
                }
                busy = false
                return
            }
            do {
                let raw = try await Task.detached(priority: .userInitiated) {
                    try saveOriginal(photo.jpegData, to: target)
                }.value
                let lastName = raw.lastPathComponent
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let processed = try processPhoto()
                        try processed.data.write(to: target.appendingPathComponent(raw.lastPathComponent), options: .withoutOverwriting)
                        return processed
                    }.value
                    var copyStatus = ""
                    if shouldCopy {
                        if let image = NSImage(data: result.data) {
                            let clipboard = NSPasteboard.general
                            clipboard.clearContents()
                            copyStatus = clipboard.writeObjects([image]) ? "已复制到剪贴板 · " : "复制到剪贴板失败 · "
                        } else {
                            copyStatus = "复制到剪贴板失败 · "
                        }
                    }
                    message = "\(lastName)：\(copyStatus)\(result.message)"
                    if result.warning { stop() }
                } catch {
                    message = "\(lastName) 原片已保存，常规 JPG 处理失败：\(error.localizedDescription)"
                    stop()
                }
                remaining = seconds
            } catch { stop(); message = "原片保存失败：\(error.localizedDescription)" }
            busy = false
        }
    }

}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    class Preview: NSView {
        let video = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; video.videoGravity = .resizeAspect; layer?.addSublayer(video) }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); video.frame = bounds; CATransaction.commit() }
    }
    func makeNSView(context: Context) -> Preview { let v = Preview(frame: .zero); v.video.session = session; return v }
    func updateNSView(_ v: Preview, context: Context) { if v.video.session !== session { v.video.session = session }; if let c = v.video.connection, c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false } }
}

private func saveOriginal(_ data: Data, to folder: URL) throws -> URL {
    let originals = folder.appendingPathComponent("原片", isDirectory: true)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    for i in 1...999999 {
        let name = String(format: "%04d.jpg", i)
        let raw = originals.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { continue }
        do {
            try data.write(to: raw, options: .withoutOverwriting)
            return raw
        } catch {
            if FileManager.default.fileExists(atPath: raw.path) { continue }
            throw error
        }
    }
    throw ScanProcessing.failure("编号已用完")
}
