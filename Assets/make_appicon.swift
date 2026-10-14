// make_appicon.swift — CanvasBar 应用图标生成器（v2.6）
// 白底 macOS 圆角方形 + Canvas 花标（红色渐变，仿官方 App 图标观感）
//
// 用法（在 CanvasBar/ 目录下）：
//   swiftc -O -parse-as-library Assets/make_appicon.swift -o .build/mkicon
//   .build/mkicon Assets/canvas-logomark-white.png .build/AppIconBuild
//   iconutil -c icns .build/AppIconBuild/AppIcon.iconset -o AppIcon.icns
//
// 产物：<outdir>/AppIcon.iconset/{icon_16x16..icon_512x512@2x}.png + preview.png

import Foundation
import CoreGraphics
import ImageIO

@main
struct MakeAppIcon {
    static let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    static func fail(_ s: String) -> Never {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: alpha)
    }

    // 花标相对整幅画布的目标直径（官方图标里花标约占宽度 72%；本图标圆角块占 80.5%）
    static let markFraction: CGFloat = 0.58
    // 红色渐变（取自官方 Canvas App 图标观感）
    static let redTop = color(0xF8493E)
    static let redBottom = color(0xC81F17)

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fail("用法: mkicon <花标png> <输出目录>")
        }
        let markPath = args[1]
        let outDir = args[2]

        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: markPath) as CFURL, nil),
              let mark = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            fail("无法读取花标: \(markPath)")
        }
        print("花标源: \(mark.width)×\(mark.height)")

        // 1) 扫描花标 alpha 包围盒（用于精确缩放/居中，容忍素材留白）
        let scanSide = 480
        var markFrac: CGFloat = 1.0
        var centerX: CGFloat = 0.5, centerY: CGFloat = 0.5
        if let sctx = CGContext(data: nil, width: scanSide, height: scanSide, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            sctx.draw(mark, in: CGRect(x: 0, y: 0, width: scanSide, height: scanSide))
            if let data = sctx.data {
                let px = data.bindMemory(to: UInt8.self, capacity: scanSide * scanSide * 4)
                var minX = scanSide, minY = scanSide, maxX = -1, maxY = -1
                for y in 0..<scanSide {
                    for x in 0..<scanSide where px[(y * scanSide + x) * 4 + 3] > 12 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
                if maxX >= minX {
                    let bw = CGFloat(maxX - minX + 1) / CGFloat(scanSide)
                    let bh = CGFloat(maxY - minY + 1) / CGFloat(scanSide)
                    markFrac = max(bw, bh)
                    centerX = ((CGFloat(minX) + CGFloat(maxX)) / 2.0) / CGFloat(scanSide)
                    // 行号自上而下 → 绘制坐标(y-up)翻转为 1-t
                    centerY = 1.0 - (((CGFloat(minY) + CGFloat(maxY)) / 2.0) / CGFloat(scanSide))
                    print(String(format: "花标包围盒: %.3f×%.3f, 中心(%.3f, %.3f)", bw, bh, centerX, centerY))
                }
            }
        }
        if markFrac < 0.2 { markFrac = 1.0 }

        // 2) 渲染函数
        func render(_ S: CGFloat) -> CGImage {
            let px = Int(S)
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                fail("无法创建画布")
            }
            ctx.interpolationQuality = .high
            ctx.setAllowsAntialiasing(true)

            // macOS 图标网格：内容圆角块 = 824/1024，带外阴影
            let margin = S * 100.0 / 1024.0
            let side = S - margin * 2
            let rect = CGRect(x: margin, y: margin, width: side, height: side)
            let radius = side * 0.225
            let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.026,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.20))
            ctx.addPath(squircle)
            ctx.setFillColor(color(0xFFFFFF))
            ctx.fillPath()
            ctx.restoreGState()

            // 底色轻微渐变（上纯白 → 下极浅灰）
            ctx.saveGState()
            ctx.addPath(squircle)
            ctx.clip()
            if let bg = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xF4F4F7)] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            }
            ctx.restoreGState()

            // 细边框（浅色背景上定形）
            ctx.saveGState()
            ctx.addPath(squircle)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07))
            ctx.setLineWidth(max(1, S * 0.0016))
            ctx.strokePath()
            ctx.restoreGState()

            // 花标：透明图层内 白色图形 → sourceIn 红色渐变染色
            let markSide = S * markFraction / markFrac
            let markRect = CGRect(x: S * 0.5 - centerX * markSide,
                                  y: S * 0.5 - centerY * markSide,
                                  width: markSide, height: markSide)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.draw(mark, in: markRect)
            ctx.saveGState()
            ctx.clip(to: markRect)
            ctx.setBlendMode(.sourceIn)
            if let g = CGGradient(colorsSpace: cs, colors: [redTop, redBottom] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: markRect.midX, y: markRect.maxY),
                                       end: CGPoint(x: markRect.midX, y: markRect.minY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            // 顶部柔光（模拟官方图标的釉面感；仅作用于花标区域）
            ctx.setBlendMode(.sourceAtop)
            if let sheen = CGGradient(colorsSpace: cs,
                                      colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.26),
                                               CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                                      locations: [0, 1]) {
                ctx.drawLinearGradient(sheen,
                                       start: CGPoint(x: markRect.minX, y: markRect.maxY),
                                       end: CGPoint(x: markRect.maxX, y: markRect.minY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
            ctx.endTransparencyLayer()

            guard let img = ctx.makeImage() else { fail("渲染失败") }
            return img
        }

        func writePNG(_ img: CGImage, _ path: String) {
            guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                          "public.png" as CFString, 1, nil) else {
                fail("无法写 \(path)")
            }
            CGImageDestinationAddImage(d, img, nil)
            if !CGImageDestinationFinalize(d) { fail("写入失败 \(path)") }
        }

        // 3) 输出 iconset
        let iconset = outDir + "/AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        let plan: [(Int, [String])] = [
            (16,   ["icon_16x16.png"]),
            (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
            (64,   ["icon_32x32@2x.png"]),
            (128,  ["icon_128x128.png"]),
            (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
            (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
            (1024, ["icon_512x512@2x.png"]),
        ]
        for (size, names) in plan {
            let img = render(CGFloat(size))
            for name in names { writePNG(img, iconset + "/" + name) }
            if size == 512 { writePNG(img, outDir + "/preview.png") }
        }
        print("OK -> \(iconset)")
    }
}
