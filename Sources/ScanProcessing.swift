import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct DocumentQuad: Sendable {
    // Vision coordinates: bottom-left origin, normalized.
    let topLeft: CGPoint; let topRight: CGPoint; let bottomRight: CGPoint; let bottomLeft: CGPoint
    var points:[CGPoint] {[topLeft,topRight,bottomRight,bottomLeft]}
    var area:CGFloat {
        let p=points
        return abs((0..<4).reduce(CGFloat(0)) { $0+p[$1].x*p[($1+1)%4].y-p[($1+1)%4].x*p[$1].y })/2
    }
    var valid:Bool {
        guard points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),area>=0.25 else{return false}
        let p=points
        let cross=(0..<4).map {i -> CGFloat in let a=p[i],b=p[(i+1)%4],c=p[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)}
        return cross.allSatisfy{$0 < -0.001}
    }
}

enum CropAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case automatic, vision, paperContour, manual, freehand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动（Vision 优先）"
        case .vision: "Vision 矩形检测"
        case .paperContour: "纸张外轮廓"
        case .manual: "手动框选"
        case .freehand: "自由圈选"
        }
    }
}

enum ScanProcessing {
    static let context = CIContext(options:[.cacheIntermediates:false])
    static func failure(_ message: String) -> NSError { NSError(domain: "ScanProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func detect(_ image:CGImage) throws -> DocumentQuad? {
        let request=VNDetectRectanglesRequest()
        // A partially occluded paper edge can be rejected at 0.85 even when the
        // resulting rectangle reports confidence 1.0. Validate geometry separately.
        request.maximumObservations=12;request.minimumConfidence=0.6;request.minimumSize=0.2
        request.minimumAspectRatio=0.25;request.maximumAspectRatio=1;request.quadratureTolerance=40
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let candidates=(request.results ?? []).filter{$0.confidence>=0.85}.map {DocumentQuad(topLeft:$0.topLeft,topRight:$0.topRight,bottomRight:$0.bottomRight,bottomLeft:$0.bottomLeft)}.filter{$0.valid}.sorted{$0.area>$1.area}
        guard let first=candidates.first else{return nil}
        // Similar competing rectangles can be a diagram or facing pages: do not guess.
        if candidates.dropFirst().contains(where: { other in
            let distance=zip(first.points,other.points).map{hypot($0.x-$1.x,$0.y-$1.y)}.max() ?? 1
            return other.area>first.area*0.8 && distance>0.06
        }) {return nil}
        return first
    }
    static func rectify(_ image:CGImage,quad:DocumentQuad) throws -> CGImage {
        guard quad.valid else{throw failure("纸张边界不可靠，保留原图")}
        let ci=CIImage(cgImage:image)
        func vector(_ p:CGPoint)->CIVector {CIVector(x:p.x*ci.extent.width,y:p.y*ci.extent.height)}
        let corrected=ci.applyingFilter("CIPerspectiveCorrection",parameters:["inputTopLeft":vector(quad.topLeft),"inputTopRight":vector(quad.topRight),"inputBottomRight":vector(quad.bottomRight),"inputBottomLeft":vector(quad.bottomLeft)])
        guard corrected.extent.width>=64,corrected.extent.height>=64,corrected.extent.width*corrected.extent.height<=12_000_000,let result=context.createCGImage(corrected,from:corrected.extent) else{throw failure("矫正范围不可靠，保留原图")}
        return result
    }
    static func a4Canvas(_ image:CGImage) throws -> CGImage {
        let portrait=image.height>=image.width
        let long=min(3508,max(image.width,image.height))
        let short=max(1,Int((Double(long)*210/297).rounded()))
        let width=portrait ? short:long, height=portrait ? long:short
        guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw failure("A4排版失败")}
        c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
        let scale=min(Double(width)/Double(image.width),Double(height)/Double(image.height))
        let w=Double(image.width)*scale,h=Double(image.height)*scale
        c.interpolationQuality = .high
        c.draw(image,in:CGRect(x:(Double(width)-w)/2,y:(Double(height)-h)/2,width:w,height:h))
        guard let result=c.makeImage() else {throw failure("A4排版失败")};return result
    }

    struct Result { let data: Data; let message: String; let warning: Bool }
    static func process(_ data: Data, rotation: Int, crop: Bool, enhancement: String, flatField: FlatFieldReference? = nil, deskew: Bool = false, cropAlgorithm: CropAlgorithm = .automatic, manualCrop: ManualCrop = .initial, manualA4: Bool = false, freehandSelection: FreehandSelection? = nil) throws -> Result {
        guard let input = CIImage(data:data) else { throw failure("无法读取照片") }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var inputImage = input
        var warning = false
        var notices: [String] = []
        let manualSelection = crop && cropAlgorithm == .manual ? manualCrop : nil
        let usesFreehand = crop && cropAlgorithm == .freehand
        let outline = usesFreehand ? freehandSelection : nil
        if usesFreehand && outline == nil { throw failure("请先在预览中圈出要保留的范围") }
        if let flatField {
            do {
                guard let raw = context.createCGImage(input,from:input.extent) else { throw failure("无法读取原片") }
                let sourceCrop = (manualSelection ?? outline?.boundingCrop)?.inSource(rotation: rotation)
                inputImage = CIImage(cgImage:try FlatField.apply(raw,reference:flatField,selection:sourceCrop))
                notices.append("已补偿纸张光照")
            } catch { warning = true; notices.append("未应用光照补偿："+error.localizedDescription) }
        }
        let rotated = inputImage.oriented(orientations[rotation % 4])
        guard var image = context.createCGImage(rotated, from:rotated.extent) else { throw failure("无法旋转照片") }
        var message = crop ? "已自动裁边、透视校正并排成 A4" : "已保存照片"
        var layoutA4 = false
        if let manualSelection {
            guard let page = manualSelection.crop(image) else { throw failure("无法按预览框裁切") }
            image = page
            layoutA4 = manualA4
            message = manualA4 ? "已按手动框选裁切并排成 A4" : "已按手动框选裁切"
        } else if usesFreehand {
            message = "已保留圈内内容，圈外填白"
        } else if crop {
            let detected = cropAlgorithm == .paperContour ? nil : try detect(image)
            let contour = detected == nil && cropAlgorithm != .vision ? PaperContour.detect(image) : nil
            if let quad = detected ?? contour, let corrected = try? rectify(image, quad:quad) {
                var page = corrected
                notices.append(contour != nil ? "裁边：纸张外轮廓" : "裁边：Vision 矩形检测")
                if deskew, let angle = TextDeskew.angle(for: page),
                   let straightened = TextDeskew.corrected(page, degrees: angle) {
                    page = straightened
                    notices.append("已校正文字行倾斜")
                }
                image = page
                layoutA4 = true
            } else {
                warning = true
                message = "\(cropAlgorithm.title)未能确认纸张四边，已保留完整画面"
            }
        }
        if enhancement == "autoPaper" {
            do {
                if (!crop || manualSelection != nil || usesFreehand || layoutA4),
                   let adjusted = try AutoPaperTone.brighten(image) {
                    image = adjusted
                    notices.append("已自动调整纸面亮度／对比度")
                } else {
                    notices.append("纸面已足够亮或无法确认，保留当前亮度")
                }
            } catch {
                warning = true
                notices.append(error.localizedDescription)
            }
        }
        if layoutA4 { image = try a4Canvas(image) }
        if enhancement != "none" && enhancement != "autoPaper" {
            do { image = try enhance(image, mode:enhancement) }
            catch { warning = true; message += "；增强失败：\(error.localizedDescription)" }
        }
        if let outline { image = try outline.cropAndFillOutsideWhite(image) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("无法生成照片") }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.96] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("无法生成照片") }
        if !notices.isEmpty { message += "；"+notices.joined(separator:"；") }
        return Result(data:output as Data, message:message, warning:warning)
    }
    static func enhance(_ image: CGImage, mode: String) throws -> CGImage {
        guard let resources = Bundle.main.resourceURL else { throw failure("找不到增强工具") }
        let executable = resources.appendingPathComponent("DocumentScan/DocumentScanEnhancer")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScanAssistant-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let input = directory.appendingPathComponent("input.png"), output = directory.appendingPathComponent("output.png")
        guard let dest = CGImageDestinationCreateWithURL(input as CFURL,UTType.png.identifier as CFString,1,nil) else { throw failure("无法准备增强图片") }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else { throw failure("无法准备增强图片") }
        let p = Process(); p.executableURL = executable; p.arguments = [input.path,output.path,mode]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value:0); p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout:.now()+45) == .timedOut { p.terminate(); if done.wait(timeout:.now()+2) == .timedOut { kill(p.processIdentifier,SIGKILL); p.waitUntilExit() }; throw failure("处理超时") }
        guard p.terminationStatus == 0, let src = CGImageSourceCreateWithURL(output as CFURL,nil), let result = CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary), result.width == image.width, result.height == image.height else { throw failure("增强工具未完成") }
        guard let bitmap = CGContext(data:nil,width:result.width,height:result.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("无法读取增强结果") }
        bitmap.draw(result,in:CGRect(x:0,y:0,width:result.width,height:result.height))
        guard let rendered = bitmap.makeImage() else { throw failure("无法读取增强结果") }
        return rendered
    }
}
