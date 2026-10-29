// Renders Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.05, green: 0.07, blue: 0.16)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            VStack(spacing: -26) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 46, style: .continuous)
                        .fill(LinearGradient(colors: [[Color(red: 0.30, green: 0.85, blue: 0.60), Color(red: 0.10, green: 0.55, blue: 0.45)],
                                                      [Color(red: 0.35, green: 0.70, blue: 1.00), Color(red: 0.15, green: 0.40, blue: 0.85)],
                                                      [Color(red: 0.75, green: 0.55, blue: 1.00), Color(red: 0.45, green: 0.30, blue: 0.85)]][i],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 520 - CGFloat(i) * 0, height: 150)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white.opacity(i == 0 ? 0.95 : 0.55)).frame(width: 34).padding(.trailing, 48)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
                        .zIndex(Double(3 - i))
                }
            }
            .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let png = rep.representation(using: .png, properties: [:])!
    let set = URL(fileURLWithPath: "/private/tmp/devstore-icon.iconset")
    try? FileManager.default.removeItem(at: set)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    let master = set.appendingPathComponent("master.png")
    try png.write(to: master)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", set.appendingPathComponent(name).path]
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
    }
    try FileManager.default.removeItem(at: master)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
    try p.run(); p.waitUntilExit()
    try png.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
    print("wrote Resources/AppIcon.icns")
}

try MainActor.assumeIsolated { try render() }
