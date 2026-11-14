import AppKit
import Foundation

// 生成 Voxi AppIcon：深蓝渐变 + 发光声波曲线。
// 运行：swift scripts/dev/generate-app-icon.swift

let outputDirectory = URL(fileURLWithPath: "Voxi/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// 圆角方块
let rect = CGRect(x: 24, y: 24, width: size - 48, height: size - 48)
let squircle = CGPath(roundedRect: rect, cornerWidth: 226, cornerHeight: 226, transform: nil)
context.saveGState()
context.addPath(squircle)
context.clip()

// 靛蓝 → 蓝 → 青 的斜向渐变
let colors = [
    NSColor(srgbRed: 0.35, green: 0.20, blue: 0.86, alpha: 1).cgColor,  // #5933DB
    NSColor(srgbRed: 0.16, green: 0.38, blue: 0.94, alpha: 1).cgColor,  // #2A61F0
    NSColor(srgbRed: 0.10, green: 0.68, blue: 0.83, alpha: 1).cgColor   // #1AADD4
]
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors as CFArray,
    locations: [0, 0.55, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)

// 顶部线性高光（避免径向渐变中心出现暗点）
let glowColors = [
    NSColor.white.withAlphaComponent(0.16).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor
]
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    glow,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.midY + 100),
    options: []
)
context.restoreGState()

// 白色波形柱
let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.92, 0.66, 0.42, 0.22]
let barWidth: CGFloat = 52
let gap: CGFloat = 38
let maxHeight: CGFloat = 430
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2

context.saveGState()
context.setShadow(offset: .zero, blur: 34, color: NSColor.white.withAlphaComponent(0.28).cgColor)
for height in heights {
    let barHeight = 100 + maxHeight * height
    let barRect = CGRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    let barGradientColors = [
        NSColor.white.cgColor,
        NSColor(srgbRed: 0.85, green: 0.93, blue: 1.0, alpha: 1).cgColor
    ]
    let barGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: barGradientColors as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.addPath(barPath)
    context.clip()
    context.drawLinearGradient(
        barGradient,
        start: CGPoint(x: barRect.midX, y: barRect.maxY),
        end: CGPoint(x: barRect.midX, y: barRect.minY),
        options: []
    )
    context.restoreGState()
    x += barWidth + gap
}
context.restoreGState()

// 内侧描边
context.saveGState()
context.addPath(squircle)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
context.setLineWidth(5)
context.strokePath()
context.restoreGState()

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
