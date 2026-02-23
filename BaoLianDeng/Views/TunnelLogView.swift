// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI

struct TunnelLogView: View {
    @State private var logText = "No log yet — toggle the VPN to generate logs."
    @State private var autoRefresh = true
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let maxBytes = 256 * 1024  // read last 256 KB

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(logText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .onChange(of: logText) {
                if autoRefresh {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Tunnel Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = logText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    Toggle(isOn: $autoRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .onAppear { loadLog() }
        .onReceive(timer) { _ in
            if autoRefresh { loadLog() }
        }
    }

    private func loadLog() {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else {
            logText = "Cannot access shared container."
            return
        }
        let logURL = dir.appendingPathComponent("tunnel.log")
        let maxBytes = self.maxBytes

        DispatchQueue.global(qos: .utility).async {
            let text = Self.readTail(url: logURL, maxBytes: maxBytes)
            DispatchQueue.main.async {
                logText = text ?? "No log yet — toggle the VPN to generate logs."
            }
        }
    }

    private static func readTail(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        if fileSize > maxBytes {
            handle.seek(toFileOffset: fileSize - UInt64(maxBytes))
            guard let data = try? handle.readToEnd(),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            // Drop the first partial line
            if let firstNewline = raw.firstIndex(of: "\n") {
                let trimmed = String(raw[raw.index(after: firstNewline)...])
                return trimmed.isEmpty ? nil : trimmed
            }
            return raw
        } else {
            handle.seek(toFileOffset: 0)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            return text
        }
    }
}
