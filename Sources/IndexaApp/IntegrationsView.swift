import SwiftUI
import AppKit
import IndexaCore

struct IntegrationsView: View {
    @ObservedObject var runtime: Runtime
    @State private var confirmRotation = false
    private let labels = ["read": "Odczyt wskazanych notatek", "create": "Tworzenie notatek", "append": "Dopisywanie do notatek"]
    var body: some View {
        Form {
            Section("Narzędzia dla agenta") {
                Text("Tutaj decydujesz, które funkcje Indexy są dostępne dla Hermesa i innych klientów MCP.")
                Label(runtime.mcpStatus, systemImage: "network")
                Text("Dostęp tylko na tym Macu, przez uwierzytelnione połączenie. Token jest w sejfie Indexy.").font(.caption).foregroundStyle(.secondary)
                if !runtime.mcpNotice.isEmpty { Text(runtime.mcpNotice).font(.callout).textSelection(.enabled) }
            }
            ForEach(runtime.mcpModules) { module in
                Section(module.title) {
                    Toggle("Udostępniaj agentowi", isOn: Binding(get: { module.enabled }, set: { enabled in
                        Task { await runtime.setMCPEnabled(enabled, module: module.id) }
                    }))
                    Text("Wyłącznie folder Indexa w domyślnym koncie Apple Notes. Bez usuwania i dostępu do pozostałych folderów.").font(.caption).foregroundStyle(.secondary)
                    ForEach(["read", "create", "append"], id: \.self) { permission in
                        Toggle(labels[permission] ?? permission, isOn: Binding(get: { module.permissions.contains(permission) }, set: { enabled in
                            Task { await runtime.setMCPPermission(permission, enabled: enabled, module: module.id) }
                        }))
                    }
                    Text("Włączenie zapisu pozwala wykonywać polecenia agenta bez osobnego pytania przy każdej notatce. Wyłączenie blokuje nowe operacje; rozpoczęty zapis może się dokończyć.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Dostępne narzędzia", value: String(module.enabled ? module.permissions.count : 0))
                    if module.enabled {
                        // Form flattens both loops: tool IDs must differ from permission IDs.
                        ForEach([("read", "notes_get"), ("create", "notes_create"), ("append", "notes_append")].filter { module.permissions.contains($0.0) }, id: \.1) { tool in
                            Text(tool.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Button("Kopiuj adres MCP") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("http://127.0.0.1:43121/mcp/notes", forType: .string)
                        }
                        Button("Test połączenia") { Task { await runtime.testMCPConnection() } }
                    }
                }
            }
            Section("Hermes") {
                Label(runtime.mcpHermesStatus, systemImage: "link")
                Text("Indexa sama podłącza swoje moduły i aktualizuje token. Wybierz uprawnienia powyżej — niczego nie musisz kopiować.").font(.caption).foregroundStyle(.secondary)
                Button("Ponów połączenie") { Task { await runtime.connectMCPToHermes() } }
                    .disabled(runtime.mcpManager == nil || runtime.mcpConnecting || runtime.mcpRotating)
                Button("Zmień token dostępu…") { confirmRotation = true }
                    .disabled(runtime.mcpManager == nil || runtime.mcpConnecting || runtime.mcpRotating)
                DisclosureGroup("Inny klient MCP") {
                    Button("Kopiuj konfigurację MCP") { runtime.copyMCPConfiguration() }.disabled(runtime.mcpManager == nil)
                    Text("Konfiguracja zawiera token. Tylko w innych klientach trzeba aktualizować go ręcznie.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Aktywność agenta") {
                Text("Ostatnie 512 wywołań od uruchomienia MCP. Bez treści notatek, poleceń i sekretów.").font(.caption).foregroundStyle(.secondary)
                if runtime.mcpActivity.isEmpty { Text("Brak wywołań narzędzi.").foregroundStyle(.secondary) }
                ForEach(runtime.mcpActivity.prefix(30)) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.tool).font(.system(.callout, design: .monospaced))
                            Text(entry.module + " · " + entry.result).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date, style: .time).font(.caption)
                        Text("\(Int(entry.duration * 1000)) ms").font(.caption).monospacedDigit()
                    }
                }
            }
            Section("Apple Home") {
                Text("Odłożone. Integracja HomeKit wymaga dodatkowego helpera i podpisywania Apple.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Zmienić token MCP?", isPresented: $confirmRotation) {
            Button("Zmień token") { Task { await runtime.rotateMCPToken() } }
        } message: { Text("Bieżące połączenia zostaną zamknięte. Poprzedni token przestanie działać, a Indexa automatycznie przekaże nowy Hermesowi.") }
    }
}
