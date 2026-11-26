#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(dirname "$PROJECT_DIR")"
APP_NAME="LuminaAI"
APP_BUNDLE="${WORKSPACE_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SDK_PATH="$(xcrun --show-sdk-path)"
MODULE_CACHE="/tmp/lumina_module_cache"
mkdir -p "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"
export SWIFT_MODULECACHE_PATH="${MODULE_CACHE}"

echo "==> Cleaning previous bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> Generating native AppIcon.icns..."
swift -module-cache-path "${MODULE_CACHE}" - "${RESOURCES_DIR}/AppIcon.icns" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments[1]
let entries: [(Int, String)] = [
    (128, "ic07"),
    (256, "ic08"),
    (512, "ic09"),
    (1024, "ic10")
]

let colorSpace = CGColorSpaceCreateDeviceRGB()
var chunks = Data()

for (px, ostype) in entries {
    let s = CGFloat(px)
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    let rect = CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let radius = s * 0.21
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    let c1 = CGColor(colorSpace: colorSpace, components: [0.13, 0.14, 0.16, 1.0])!
    let c2 = CGColor(colorSpace: colorSpace, components: [0.24, 0.25, 0.28, 1.0])!
    let grad = CGGradient(colorsSpace: colorSpace, colors: [c1, c2] as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let cx = s / 2
    let cy = s / 2
    let outer = s * 0.27
    let inner = s * 0.075
    let star = CGMutablePath()
    star.move(to: CGPoint(x: cx, y: cy + outer))
    star.addQuadCurve(to: CGPoint(x: cx + outer, y: cy), control: CGPoint(x: cx + inner, y: cy + inner))
    star.addQuadCurve(to: CGPoint(x: cx, y: cy - outer), control: CGPoint(x: cx + inner, y: cy - inner))
    star.addQuadCurve(to: CGPoint(x: cx - outer, y: cy), control: CGPoint(x: cx - inner, y: cy - inner))
    star.addQuadCurve(to: CGPoint(x: cx, y: cy + outer), control: CGPoint(x: cx - inner, y: cy + inner))
    star.closeSubpath()

    ctx.addPath(star)
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.92, 0.86, 0.74, 1.0])!)
    ctx.fillPath()

    guard let cgImg = ctx.makeImage() else { continue }
    let pngData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(pngData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, cgImg, nil)
    CGImageDestinationFinalize(dest)

    let data = pngData as Data
    var chunkLen = UInt32(8 + data.count).bigEndian
    chunks.append(ostype.data(using: .ascii)!)
    chunks.append(Data(bytes: &chunkLen, count: 4))
    chunks.append(data)
}

var icns = Data()
var totalLen = UInt32(8 + chunks.count).bigEndian
icns.append("icns".data(using: .ascii)!)
icns.append(Data(bytes: &totalLen, count: 4))
icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: outputPath))
SWIFT

echo "==> Copying Info.plist..."
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

echo "==> Compiling Swift sources with swiftc (arm64, zero SwiftUI macros)..."
swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${MODULE_CACHE}" \
    -O \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Carbon \
    -framework Vision \
    -framework ScreenCaptureKit \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -o "${MACOS_DIR}/${APP_NAME}" \
    "${PROJECT_DIR}/Sources/Models.swift" \
    "${PROJECT_DIR}/Sources/AppLogger.swift" \
    "${PROJECT_DIR}/Sources/PermissionManager.swift" \
    "${PROJECT_DIR}/Sources/UsageStore.swift" \
    "${PROJECT_DIR}/Sources/UpdateManager.swift" \
    "${PROJECT_DIR}/Sources/AIClient.swift" \
    "${PROJECT_DIR}/Sources/GlobalHotkeyManager.swift" \
    "${PROJECT_DIR}/Sources/TextSelectionMonitor.swift" \
    "${PROJECT_DIR}/Sources/ScreenCaptureManager.swift" \
    "${PROJECT_DIR}/Sources/FloatingPanels.swift" \
    "${PROJECT_DIR}/Sources/DesignSystem.swift" \
    "${PROJECT_DIR}/Sources/DashboardViews.swift" \
    "${PROJECT_DIR}/Sources/AppDelegate.swift" \
    "${PROJECT_DIR}/Sources/main.swift"

SIGN_ID="LuminaAI Local Signer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
    echo "==> Signing ${APP_BUNDLE} with persistent certificate '${SIGN_ID}' (preserves macOS TCC permissions)..."
    codesign --force --deep --sign "${SIGN_ID}" \
        -r="designated => identifier \"com.lumina.ai.assistant\" and certificate leaf[subject.CN] = \"${SIGN_ID}\"" \
        "${APP_BUNDLE}"
else
    echo "==> Local certificate '${SIGN_ID}' not found, using ad-hoc signature..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "==> Build succeeded: ${APP_BUNDLE}"
