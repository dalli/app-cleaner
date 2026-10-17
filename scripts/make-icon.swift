// 앱 아이콘 만들기: packaging/icon/AppIcon.svg → packaging/icon/AppIcon.icns
//
//   swift scripts/make-icon.swift            # 저장소 루트에서 실행
//
// SVG 원본을 iconset 크기(16~1024, @2x 포함)로 그려 iconutil로 icns를 만든다. 결과 icns는 저장소에 커밋하고
// scripts/build-app.sh가 앱·Sentinel 번들에 복사한다 (릴리즈 러너에서 다시 그리지 않음).
// NSImage의 SVG 렌더러는 SVG 필터를 그리지 않으므로 macOS 아이콘 그림자는 여기서 NSShadow로 넣는다.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("packaging/icon/AppIcon.svg")
let icns = root.appendingPathComponent("packaging/icon/AppIcon.icns")

guard let image = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write(Data("error: \(svg.path)을 읽지 못했습니다 (저장소 루트에서 실행하세요)\n".utf8))
    exit(1)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // macOS 아이콘 템플릿의 그림자 (1024 기준: 아래로 12, 흐림 28, 불투명도 0.3)
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("error: iconutil 실패 (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print(icns.path)
