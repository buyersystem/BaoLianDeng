// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI
import UIKit

struct TunnelLogView: View {
    @State private var logText = "No log yet — toggle the VPN to generate logs."
    @State private var autoRefresh = true
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
        if let text = try? String(contentsOf: logURL, encoding: .utf8), !text.isEmpty {
            logText = text
        } else {
            logText = "No log yet — toggle the VPN to generate logs."
        }
    }
}
