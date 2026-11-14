import AppKit
import Foundation

// 生成 Voxi AppIcon：1024 底图 + 全套尺寸 PNG。
// 运行：swift scripts/dev/generate-app-icon.swift

let outputDirectory = URL(fileURLWithPath: "Voxi/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// 背景圆角方块
let rect = CGRect(x: 24, y: 24, width: size - 48, height: size - 48)
let path = CGPath(roundedRect: rect, cornerWidth: 220, cornerHeight: 220, transform: nil)
context.saveGState()
context.addPath(path)
context.clip()
let colors = [
    NSColor(srgbRed: 0.23, green: 0.47, blue: 0.96, alpha: 1).cgColor,   // 蓝
    NSColor(srgbRed: 0.55, green: 0.33, blue: 0.95, alpha: 1).cgColor    // 紫
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)
// 顶部高光
context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
context.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
context.restoreGState()

// 白色波形：中间高、两侧低
let heights: [CGFloat] = [0.18, 0.30, 0.46, 0.66, 0.86, 0.66, 0.46, 0.30, 0.18]
let barWidth: CGFloat = 46
let gap: CGFloat = 30
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
context.setShadow(offset: .zero, blur: 26, color: NSColor.black.withAlphaComponent(0.28).cgColor)
context.setFillColor(NSColor.white.cgColor)
for height in heights {
    let h = 440 * height + 90
    let bar = CGRect(x: x, y: (size - h) / 2, width: barWidth, height: h)
    let barPath = CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    context.addPath(barPath)
    context.fillPath()
    x += barWidth + gap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("render failed")
}
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
let master = outputDirectory.appendingPathComponent("master_1024.png")
try png.write(to: master)
defer { try? FileManager.default.removeItem(at: master) }

func downscale(_ pixels: Int, name: String) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", outputDirectory.appendingPathComponent(name).path]
    try task.run()
    task.waitUntilExit()
}

let variants: [(Int, String)] = [
    (16, "icon_16.png"), (32, "icon_16@2x.png"),
    (32, "icon_32.png"), (64, "icon_32@2x.png"),
    (128, "icon_128.png"), (256, "icon_128@2x.png"),
    (256, "icon_256.png"), (512, "icon_256@2x.png"),
    (512, "icon_512.png"), (1024, "icon_512@2x.png")
]
for (pixels, name) in variants {
    try downscale(pixels, name: name)
}

let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "size": "16x16", "scale": "1x", "filename": "icon_16.png"],
        ["idiom": "mac", "size": "16x16", "scale": "2x", "filename": "icon_16@2x.png"],
        ["idiom": "mac", "size": "32x32", "scale": "1x", "filename": "icon_32.png"],
        ["idiom": "mac", "size": "32x32", "scale": "2x", "filename": "icon_32@2x.png"],
        ["idiom": "mac", "size": "128x128", "scale": "1x", "filename": "icon_128.png"],
        ["idiom": "mac", "size": "128x128", "scale": "2x", "filename": "icon_128@2x.png"],
        ["idiom": "mac", "size": "256x256", "scale": "1x", "filename": "icon_256.png"],
        ["idiom": "mac", "size": "256x256", "scale": "2x", "filename": "icon_256@2x.png"],
        ["idiom": "mac", "size": "512x512", "scale": "1x", "filename": "icon_512.png"],
        ["idiom": "mac", "size": "512x512", "scale": "2x", "filename": "icon_512@2x.png"]
    ],
    "info": ["author": "xcode", "version": 1]
]
let contentsData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try contentsData.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("icon set written to \(outputDirectory.path)")
