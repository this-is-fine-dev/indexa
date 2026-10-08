import SwiftUI
import AppKit
import IndexaCore

struct IntegrationsView: View {
    @ObservedObject var runtime: Runtime
    @State private var confirmRotation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Integracje").font(.largeTitle.bold())
                    Text("Wybierz, z czego może korzystać Hermes. Połączenie skonfigurujemy automatycznie.")
                        .foregroundStyle(.secondary)
                }
                if runtime.mcpModules.isEmpty {
                    Label(runtime.mcpStatus, systemImage: "network").padding()
                }
                ForEach(runtime.mcpModules) { module in
                    MCPModuleCard(runtime: runtime, module: module)
                }
                if !runtime.mcpNotice.isEmpty {
                    HStack(alignment: .top) {
                        Text(runtime.mcpNotice).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { runtime.mcpNotice = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Zamknij komunikat")
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                DisclosureGroup("Ostatnia aktywność") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bez treści, argumentów i sekretów. Historia od uruchomienia aplikacji.")
                            .font(.caption).foregroundStyle(.secondary)
                        if runtime.mcpActivity.isEmpty { Text("Hermes nie użył jeszcze narzędzi w tej sesji.").foregroundStyle(.secondary) }
                        ForEach(runtime.mcpActivity.prefix(30)) { entry in
                            HStack(alignment: .top) {
                                Image(systemName: entry.result == "ok" ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(entry.result == "ok" ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.tool).font(.callout.monospaced()).textSelection(.enabled)
                                    Text(entry.diagnostic ?? (entry.result == "ok" ? "Wykonano" : entry.result == "denied" ? "Zablokowano przez uprawnienia" : "Operacja nie powiodła się"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary).fixedSize()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
                DisclosureGroup("Ustawienia zaawansowane MCP") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                if runtime.mcpConnecting {
                                    ProgressView().controlSize(.small).accessibilityLabel("Łączenie z Hermesem")
                                } else {
                                    Image(systemName: runtime.mcpHermesConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .foregroundStyle(runtime.mcpHermesConnected ? Color.green : Color.orange)
                                }
                                Text(runtime.mcpHermesStatus).font(.callout)
                            }
                            Text(runtime.mcpStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Button(runtime.mcpConnecting ? "Łączenie z Hermesem…" : "Ponów połączenie") {
                                Task { await runtime.connectMCPToHermes() }
                            }.disabled(runtime.mcpManager == nil || runtime.mcpConnecting || runtime.mcpRotating)
                            Text("Indexa łączy narzędzia automatycznie. Ponów, jeśli Hermes ich nie widzi.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Kopiuj konfigurację") { runtime.copyMCPConfiguration() }
                                .disabled(runtime.mcpManager == nil || runtime.mcpRotating)
                            Text("Tylko dla innego klienta MCP. Zawiera token dostępu; schowek wyczyści się po minucie. Hermes nie wymaga kopiowania.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Button(runtime.mcpRotating ? "Zmienianie tokena…" : "Zmień token dostępu…") { confirmRotation = true }
                                    .disabled(runtime.mcpManager == nil || runtime.mcpConnecting || runtime.mcpRotating)
                                if runtime.mcpRotating { ProgressView().controlSize(.small) }
                            }
                            Text("Unieważnia poprzedni token. Indexa połączy Hermesa ponownie; konfigurację innych klientów trzeba zmienić ręcznie.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .disclosureGroupStyle(IntegrationDisclosureStyle())
        .confirmationDialog("Zmienić token MCP?", isPresented: $confirmRotation) {
            Button("Zmień token") { Task { await runtime.rotateMCPToken() } }
        } message: { Text("Bieżące połączenia zostaną zamknięte. Poprzedni token przestanie działać, a Indexa automatycznie przekaże nowy Hermesowi.") }
    }
}

private struct IntegrationDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: DisclosureGroupStyleConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    configuration.label.font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Rozwinięte" : "Zwinięte")
            .accessibilityHint(configuration.isExpanded ? "Zwiń szczegóły" : "Pokaż szczegóły")
            if configuration.isExpanded {
                Divider().padding(.vertical, 10)
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MCPModuleCard: View {
    @ObservedObject var runtime: Runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let module: MCPModuleState
    @State private var expanded = false
    private var latest: MCPAuditEntry? { runtime.mcpActivity.first { $0.module == module.id } }
    private var symbol: String { ["files": "doc.richtext", "notes": "note.text", "reminders": "checklist", "calendar": "calendar"][module.id] ?? "puzzlepiece.extension" }
    private var status: (String, String, Color) {
        if !module.enabled { return ("Wyłączone", "minus.circle", .secondary) }
        if runtime.mcpManager == nil { return ("Serwer niedostępny", "exclamationmark.circle.fill", .orange) }
        if module.permissions.isEmpty { return ("Wybierz uprawnienia", "exclamationmark.circle", .orange) }
        if let issue = runtime.organizerIssues[module.id] { return (issue, "exclamationmark.circle", .orange) }
        if runtime.mcpConnecting { return ("Łączenie z Hermesem…", "clock", .secondary) }
        if !runtime.mcpHermesConnected { return ("MCP niepołączone z Hermesem", "exclamationmark.circle.fill", .orange) }
        if !runtime.hermesConnected { return ("Hermes niedostępny", "exclamationmark.circle", .orange) }
        if let latest, latest.result != "ok" {
            return (latest.result == "denied" ? "Ostatnie wywołanie zablokowane" : "Ostatnia operacja nie powiodła się", "exclamationmark.circle.fill", .orange)
        }
        return (latest == nil ? "Gotowe do użycia" : "Działa · ostatnia operacja poprawna", "checkmark.circle.fill", .green)
    }
    private var permissions: [String] { ["read", "create", "append", "complete"].filter { module.availablePermissions.contains($0) } }
    private func label(_ permission: String) -> String {
        switch permission {
        case "read": return module.id == "notes" ? "Odczyt wskazanych notatek" : "Odczyt"
        case "create": return "Tworzenie"
        case "append": return "Dopisywanie do notatek"
        case "complete": return "Oznaczanie jako wykonane"
        default: return permission
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(module.title).font(.headline)
                    HStack(alignment: .top, spacing: 6) {
                        if module.enabled && runtime.mcpConnecting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: status.1)
                        }
                        Text(status.0).fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(status.2)
                }
                Spacer(minLength: 12)
                Toggle("Udostępnij \(module.title) Hermesowi", isOn: Binding(get: { module.enabled }, set: { enabled in
                    if enabled && module.permissions.isEmpty {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded = true }
                    }
                    Task { await runtime.setMCPEnabled(enabled, module: module.id) }
                })).labelsHidden().toggleStyle(.switch).disabled(runtime.mcpManager == nil)
            }
            if module.enabled, let latest, latest.result == "error" {
                Text(latest.diagnostic ?? "Operacja nie powiodła się. Rozwiń ostatnią aktywność, aby sprawdzić szczegóły.")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            DisclosureGroup("Dostęp i szczegóły", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(module.id == "notes" ? "Tylko folder Indexa w domyślnym koncie Notatek. Bez usuwania." : runtime.organizerScopeDescription(module.id))
                        .font(.caption).foregroundStyle(.secondary)
                    if ["calendar","reminders"].contains(module.id) { OrganizerAccessView(runtime: runtime, module: module) }
                    ForEach(permissions, id: \.self) { permission in
                        Toggle(label(permission), isOn: Binding(get: { module.permissions.contains(permission) }, set: { enabled in
                            Task { await runtime.setMCPPermission(permission, enabled: enabled, module: module.id) }
                        })).toggleStyle(.switch).disabled(runtime.mcpManager == nil)
                    }
                    Text("Włączenie zapisu pozwala wykonywać polecenia bez potwierdzania każdej zmiany. Wyłączenie blokuje nowe operacje; rozpoczęta może się dokończyć.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Kopiuj adres MCP") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://127.0.0.1:43121/mcp/" + module.id, forType: .string)
                        runtime.mcpNotice = "Skopiowano adres \(module.title). Hermes nie wymaga ręcznej konfiguracji."
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.callout)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
}

private struct OrganizerAccessView: View {
    @ObservedObject var runtime: Runtime
    let module: MCPModuleState
    var body: some View {
        if runtime.organizerIssues[module.id] != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Najpierw zezwól Indexie na dostęp w macOS.").font(.callout)
                HStack(spacing: 8) {
                    Button("Zezwól na dostęp…") { Task { await runtime.requestOrganizerAccess(module.id) } }
                        .disabled(runtime.organizerRequesting || runtime.organizerStore == nil)
                    if runtime.organizerRequesting { ProgressView().controlSize(.small) }
                }
            }
            Text("macOS prosi o pełny dostęp dla aplikacji. Narzędzia Hermesa ograniczają osobne przełączniki poniżej.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Zgoda macOS udzielona", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
        }
    }
}
