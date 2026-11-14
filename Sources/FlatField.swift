import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct FlatFieldReference: Codable, Sendable {
    let deviceID: String
    let width: Int
    let height: Int
    let jpeg: Data
    let points: [Double]
    static var file: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("ScanAssistant",isDirectory:true).appendingPathComponent("flat-field.json")
    }
    static func make(data:Data, deviceID:String) throws -> FlatFieldReference {
        guard !deviceID.isEmpty, let src=CGImageSourceCreateWithData(data as CFData,nil), let image=CGImageSourceCreateImageAtIndex(src,0,nil), let quad=try ScanProcessing.detect(image) else { throw ScanProcessing.failure("未识别到完整白纸，请铺平白纸并露出四边后重试。") }
        let p = quad.points.flatMap { [Double($0.x),Double($0.y)] }
        return FlatFieldReference(deviceID:deviceID,width:image.width,height:image.height,jpeg:data,points:p)
    }
    func save() throws {
        try FileManager.default.createDirectory(at:Self.file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(self).write(to:Self.file,options:.atomic)
    }
    static func load(deviceID:String) -> FlatFieldReference? {
        let candidates = [file, Bundle.main.resourceURL?.appendingPathComponent("flat-field-default.json")].compactMap{$0}
        for url in candidates {
            guard let data=try? Data(contentsOf:url), let ref=try? JSONDecoder().decode(Self.self,from:data), ref.deviceID == deviceID else { continue }
            return ref
        }
        return nil
    }
    var quad: DocumentQuad? {
        guard points.count == 8 else {return nil}
        let q=DocumentQuad(topLeft:CGPoint(x:points[0],y:points[1]),topRight:CGPoint(x:points[2],y:points[3]),bottomRight:CGPoint(x:points[4],y:points[5]),bottomLeft:CGPoint(x:points[6],y:points[7]))
        return q.valid ? q : nil
    }
}

enum FlatField {
    static let kernel = CIColorKernel(source: """
        kernel vec4 flatField(__sample inputImage, __sample referenceImage, float referenceLevel) {
            float luma = dot(referenceImage.rgb, vec3(0.2126, 0.7152, 0.0722));
            float factor = clamp(referenceLevel / max(luma, 0.02), 1.0, 1.75);
            return vec4(min(inputImage.rgb * factor, vec3(1.0)), inputImage.a);
        }
        """)
    static func apply(_ image:CGImage, reference:FlatFieldReference, selection: ManualCrop? = nil) throws -> CGImage {
        guard image.width == reference.width, image.height == reference.height, let quad=reference.quad,
              let ref=CIImage(data:reference.jpeg), let kernel else {
            throw ScanProcessing.failure("光照补偿需要相同分辨率且完整识别 A4 纸张，请重新校准或调整纸张。")
        }
        let w=CGFloat(image.width),h=CGFloat(image.height)
        // Use a safely inset rectangle within the reference paper so the dark desk is never sampled.
        let left=max(quad.topLeft.x,quad.bottomLeft.x), right=min(quad.topRight.x,quad.bottomRight.x)
        let bottom=max(quad.bottomLeft.y,quad.bottomRight.y), top=min(quad.topLeft.y,quad.topRight.y)
        let dx=(right-left)*0.07,dy=(top-bottom)*0.07
        let region=CGRect(x:(left+dx)*w,y:(bottom+dy)*h,width:(right-left-2*dx)*w,height:(top-bottom-2*dy)*h)
        guard region.width > w*0.15, region.height > h*0.15 else {throw ScanProcessing.failure("白纸区域过小，请重新校准。")}
        let blur=ref.cropped(to:region).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(w,h)*0.025]).cropped(to:CGRect(x:0,y:0,width:w,height:h))
        // The reference level comes from a broad central patch, never from desk/background pixels.
        let center=CGRect(x:region.midX-region.width*0.10,y:region.midY-region.height*0.10,width:region.width*0.20,height:region.height*0.20)
        let avg=blur.cropped(to:center).applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:center)])
        var pixel=[Float](repeating:0,count:4)
        ScanProcessing.context.render(avg,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
        let level=0.2126*Double(pixel[0])+0.7152*Double(pixel[1])+0.0722*Double(pixel[2])
        guard level > 0.02, level < 0.96 else {throw ScanProcessing.failure("校准白纸过暗或过曝，请调整灯光后重新校准。")}
        let source=CIImage(cgImage:image), bounds=source.extent
        guard let corrected=kernel.apply(extent:bounds,arguments:[source,blur,level]) else {throw ScanProcessing.failure("光照补偿失败")}
        let paperMask: CIImage
        if let selection {
            let rect = selection.inImage(of: bounds.size)
            let region = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
            paperMask = CIImage(color: .white).cropped(to: region)
        } else {
            guard let targetQuad = try ScanProcessing.detect(image) else {
                throw ScanProcessing.failure("未识别到用于光照补偿的 A4 纸张。")
            }
            let white = CIImage(color: .white).cropped(to: bounds)
            func v(_ p: CGPoint) -> CIVector { CIVector(x:p.x*w,y:p.y*h) }
            paperMask = white.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":v(targetQuad.topLeft),"inputTopRight":v(targetQuad.topRight),"inputBottomRight":v(targetQuad.bottomRight),"inputBottomLeft":v(targetQuad.bottomLeft)])
        }
        let mask = paperMask
            .composited(over:CIImage(color:CIColor.black).cropped(to:bounds)).cropped(to:bounds)
        let output=corrected.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:mask])
        guard let result=ScanProcessing.context.createCGImage(output,from:bounds) else {throw ScanProcessing.failure("光照补偿失败")}
        return result
    }
}
