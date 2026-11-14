import AppKit
let size = 1024
let image = NSImage(size:NSSize(width:size,height:size))
image.lockFocus()
let bg = NSBezierPath(roundedRect:NSRect(x:40,y:40,width:944,height:944),xRadius:220,yRadius:220)
bg.addClip()
NSGradient(starting:NSColor(calibratedRed:0.08,green:0.34,blue:0.43,alpha:1),ending:NSColor(calibratedRed:0.08,green:0.60,blue:0.55,alpha:1))!.draw(in:NSRect(x:40,y:40,width:944,height:944),angle:55)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width:0,height:-10); shadow.set()
NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:278,y:160,width:468,height:600),xRadius:32,yRadius:32).fill()
NSShadow().set()
NSColor(calibratedRed:0.83,green:0.93,blue:0.91,alpha:1).setFill()
for y in [585,510,435,360] { NSBezierPath(roundedRect:NSRect(x:340,y:y,width:(y == 360 ? 210 : 340),height:24),xRadius:12,yRadius:12).fill() }
let dark=NSColor(calibratedRed:0.06,green:0.20,blue:0.25,alpha:1);dark.setFill()
NSBezierPath(roundedRect:NSRect(x:428,y:737,width:168,height:110),xRadius:35,yRadius:35).fill()
NSBezierPath(roundedRect:NSRect(x:360,y:814,width:304,height:65),xRadius:30,yRadius:30).fill()
NSColor(calibratedRed:0.45,green:0.93,blue:0.80,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:481,y:760,width:62,height:62)).fill()
NSColor(calibratedRed:0.1,green:0.36,blue:0.39,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:496,y:775,width:32,height:32)).fill()
let corners=NSBezierPath(); corners.lineWidth=17; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
for (x,y,sx,sy) in [(319,700,1,-1),(705,700,-1,-1),(319,218,1,1),(705,218,-1,1)] { corners.move(to:NSPoint(x:x+sx*49,y:y)); corners.line(to:NSPoint(x:x,y:y)); corners.line(to:NSPoint(x:x,y:y+sy*49)) }
NSColor(calibratedRed:0.17,green:0.69,blue:0.59,alpha:1).setStroke();corners.stroke()
image.unlockFocus()
guard let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) else { fatalError("icon") }
try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
