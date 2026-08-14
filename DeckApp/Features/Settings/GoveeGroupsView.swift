import SwiftUI

struct GoveeGroupsView: View {
    @Environment(AppState.self) private var appState
    @State private var editingGroup: GoveeDeviceGroup?
    @State private var isPresentingNewGroup = false

    var body: some View {
        Form {
            Section {
                if appState.goveeDevices.isEmpty {
                    Text("Discover Govee devices first, then group them here to control brightness, color, and color temperature together.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if appState.goveeGroups.isEmpty {
                    Text("No groups yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.goveeGroups) { group in
                        Button {
                            editingGroup = group
                        } label: {
                            LabeledContent {
                                Text("\(group.memberDeviceIDs.count) light\(group.memberDeviceIDs.count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label(group.name, systemImage: "lightbulb.2.fill")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            appState.removeGoveeGroup(id: appState.goveeGroups[index].id)
                        }
                    }
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("Groups only exist inside DeckApp. Controlling a group sends an individual command to each member device — Govee's cloud API has no native multi-device command.")
            }

            Section {
                Button {
                    isPresentingNewGroup = true
                } label: {
                    Label("New Group", systemImage: "plus.circle.fill")
                }
                .disabled(appState.goveeDevices.isEmpty)
            }
        }
        .navigationTitle("Govee Groups")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPresentingNewGroup) {
            GoveeGroupEditorView(group: nil)
        }
        .sheet(item: $editingGroup) { group in
            GoveeGroupEditorView(group: group)
        }
    }
}

private struct GoveeGroupEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let group: GoveeDeviceGroup?

    @State private var name: String
    @State private var selectedDeviceIDs: Set<String>

    init(group: GoveeDeviceGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _selectedDeviceIDs = State(initialValue: Set(group?.memberDeviceIDs ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Group name", text: $name)
                }

                Section {
                    ForEach(appState.goveeDevices) { device in
                        Button {
                            if selectedDeviceIDs.contains(device.id) {
                                selectedDeviceIDs.remove(device.id)
                            } else {
                                selectedDeviceIDs.insert(device.id)
                            }
                        } label: {
                            HStack {
                                Label(device.deviceName, systemImage: "lightbulb.led")
                                Spacer()
                                if selectedDeviceIDs.contains(device.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DesignToken.Color.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Only controls shared by every member (like power and brightness) appear on the group widget.")
                }

                if group != nil {
                    Section {
                        Button("Delete Group", role: .destructive) {
                            if let group {
                                appState.removeGoveeGroup(id: group.id)
                            }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(group == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if var group {
                            group.name = trimmedName
                            group.memberDeviceIDs = Array(selectedDeviceIDs)
                            appState.updateGoveeGroup(group)
                        } else {
                            appState.addGoveeGroup(name: trimmedName, memberDeviceIDs: Array(selectedDeviceIDs))
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedDeviceIDs.isEmpty)
                }
            }
        }
    }
}
