// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI
import Charts

struct TrafficView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var trafficStore: TrafficStore

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                chartSection
                monthlySummarySection
                statusSection
            }
            .navigationTitle("Data")
            .onAppear {
                if vpnManager.isConnected {
                    trafficStore.startPolling()
                }
            }
            .onDisappear {
                trafficStore.stopPolling()
            }
            .onChange(of: vpnManager.isConnected) { _, connected in
                if connected {
                    trafficStore.resetSession()
                    trafficStore.startPolling()
                } else {
                    trafficStore.stopPolling()
                }
            }
        }
    }

    // MARK: - Current Session (Proxy Only)

    private var sessionSection: some View {
        Section("Current Session (Proxy Only)") {
            HStack {
                Label("Upload", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Text(formatBytes(trafficStore.sessionProxyUpload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(formatBytes(trafficStore.sessionProxyDownload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Total", systemImage: "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(.purple)
                Spacer()
                Text(formatBytes(trafficStore.sessionTotal))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Daily Bar Chart

    private var chartSection: some View {
        Section("Daily Proxy Traffic (Last 30 Days)") {
            if chartEntries.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.bar",
                    description: Text("Traffic data will appear here when VPN is active")
                )
                .frame(height: 200)
            } else {
                let dayCount = Set(chartEntries.map(\.dayLabel)).count
                let chartWidth = max(CGFloat(dayCount) * 28, 300)
                ScrollView(.horizontal, showsIndicators: false) {
                    Chart(chartEntries, id: \.id) { entry in
                        BarMark(
                            x: .value("Day", entry.dayLabel),
                            y: .value("Bytes", entry.megabytes)
                        )
                        .foregroundStyle(by: .value("Direction", entry.category))
                    }
                    .chartForegroundStyleScale([
                        "Upload": Color.blue,
                        "Download": Color.green,
                    ])
                    .chartYAxisLabel("MB")
                    .frame(width: chartWidth, height: 200)
                }
                .defaultScrollAnchor(.trailing)
            }
        }
    }

    // MARK: - Monthly Summary

    private var monthlySummarySection: some View {
        Section("Monthly Summary") {
            HStack {
                Label("Upload", systemImage: "arrow.up.circle")
                    .foregroundStyle(.blue)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthUpload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Download", systemImage: "arrow.down.circle")
                    .foregroundStyle(.green)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthDownload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Total", systemImage: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.purple)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthTotal))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Connection")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(vpnManager.isConnected ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(vpnManager.isConnected ? "Active" : "Inactive")
                        .foregroundStyle(.secondary)
                }
            }

            if vpnManager.isConnected {
                HStack {
                    Text("Active Connections")
                    Spacer()
                    Text("\(trafficStore.activeProxyCount) proxy / \(trafficStore.activeTotalCount) total")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Chart Data

    private var chartEntries: [TrafficChartEntry] {
        let records = trafficStore.dailyRecords.sorted { $0.date < $1.date }
        var entries: [TrafficChartEntry] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "M/d"
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        for record in records {
            let dayLabel: String
            if let date = formatter.date(from: record.date) {
                dayLabel = displayFormatter.string(from: date)
            } else {
                dayLabel = String(record.date.suffix(5))
            }
            entries.append(TrafficChartEntry(
                dayLabel: dayLabel, date: record.date,
                megabytes: Double(record.proxyUpload) / 1_048_576.0,
                category: "Upload"
            ))
            entries.append(TrafficChartEntry(
                dayLabel: dayLabel, date: record.date,
                megabytes: Double(record.proxyDownload) / 1_048_576.0,
                category: "Download"
            ))
        }
        return entries
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

private struct TrafficChartEntry {
    let dayLabel: String
    let date: String
    let megabytes: Double
    let category: String

    var id: String { "\(date)-\(category)" }
}

#Preview {
    TrafficView()
        .environmentObject(VPNManager.shared)
        .environmentObject(TrafficStore.shared)
}
