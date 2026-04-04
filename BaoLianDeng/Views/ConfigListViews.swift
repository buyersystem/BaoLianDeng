// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Proxy Groups List View

struct ProxyGroupsListView: View {
    @Binding var proxyGroups: [EditableProxyGroup]
    let subscriptionProxyGroups: [EditableProxyGroup]
    let isSub: Bool

    @State private var searchText = ""
    @State private var showAddGroup = false

    private var groups: [EditableProxyGroup] {
        isSub ? subscriptionProxyGroups : proxyGroups
    }

    private var filteredGroups: [EditableProxyGroup] {
        guard !searchText.isEmpty else { return groups }
        let query = searchText.lowercased()
        return groups.filter {
            $0.name.lowercased().contains(query)
                || $0.type.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if isSub {
                ForEach(filteredGroups) { group in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: .constant(group), isEditable: false
                        )
                    } label: { ProxyGroupRowView(group: group) }
                }
            } else {
                ForEach(filteredIndices, id: \.self) { index in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: $proxyGroups[index], isEditable: true
                        )
                    } label: {
                        ProxyGroupRowView(group: proxyGroups[index])
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            proxyGroups.remove(at: index)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search proxy groups")
        .navigationTitle("Proxy Groups")
        .toolbar {
            if !isSub {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddGroup) {
            AddProxyGroupSheet { proxyGroups.append($0) }
        }
    }

    private var filteredIndices: [Int] {
        guard !searchText.isEmpty else {
            return Array(proxyGroups.indices)
        }
        let query = searchText.lowercased()
        return proxyGroups.indices.filter { index in
            proxyGroups[index].name.lowercased().contains(query)
                || proxyGroups[index].type.lowercased().contains(query)
        }
    }
}

// MARK: - Rules List View

struct RulesListView: View {
    @Binding var rules: [EditableRule]
    let subscriptionRules: [EditableRule]
    let proxyGroupNames: [String]
    let isSub: Bool

    @State private var searchText = ""
    @State private var showAddRule = false
    @State private var editingRuleIndex: Int?

    private var sourceRules: [EditableRule] {
        isSub ? subscriptionRules : rules
    }

    private var filteredRules: [EditableRule] {
        guard !searchText.isEmpty else { return sourceRules }
        let query = searchText.lowercased()
        return sourceRules.filter {
            $0.type.lowercased().contains(query)
                || $0.value.lowercased().contains(query)
                || $0.target.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if isSub {
                ForEach(filteredRules) { RuleRowView(rule: $0) }
            } else {
                ForEach(filteredIndices, id: \.self) { index in
                    RuleRowView(rule: rules[index])
                        .contextMenu {
                            Button("Edit") {
                                editingRuleIndex = index
                            }
                            Button("Delete", role: .destructive) {
                                rules.remove(at: index)
                            }
                        }
                }
                .onDelete { offsets in
                    let indices = offsets.map { filteredIndices[$0] }
                    for index in indices.sorted().reversed() {
                        rules.remove(at: index)
                    }
                }
                .onMove { from, dest in
                    guard searchText.isEmpty else { return }
                    rules.move(fromOffsets: from, toOffset: dest)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search rules")
        .navigationTitle("Rules (\(sourceRules.count))")
        .toolbar {
            if !isSub {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddRule = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRule) {
            AddRuleSheet(
                groupNames: proxyGroupNames
            ) { rules.append($0) }
        }
        .sheet(isPresented: Binding(
            get: { editingRuleIndex != nil },
            set: { if !$0 { editingRuleIndex = nil } }
        )) {
            if let index = editingRuleIndex {
                EditRuleSheet(
                    groupNames: proxyGroupNames,
                    rule: rules[index]
                ) { updated in
                    rules[index] = updated
                }
            }
        }
    }

    private var filteredIndices: [Int] {
        guard !searchText.isEmpty else {
            return Array(rules.indices)
        }
        let query = searchText.lowercased()
        return rules.indices.filter { index in
            rules[index].type.lowercased().contains(query)
                || rules[index].value.lowercased().contains(query)
                || rules[index].target.lowercased().contains(query)
        }
    }
}
