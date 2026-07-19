import SwiftUI
import VtaMobileAgent

/// Root of the app: a bottom tab bar that splits the agent into focused
/// contexts — Home (status), Test, History, Logs, and Settings (config). The
/// selected theme is applied app-wide and the connection status is always
/// visible via the nav-bar pill on every tab.
struct ContentView: View {
    @StateObject private var model = AgentModel.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var router = AppRouter()

    var body: some View {
        TabView(selection: $router.tab) {
            HomeTab()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)
            TestTab()
                .tabItem { Label("Test", systemImage: "bolt.fill") }
                .tag(Tab.test)
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(Tab.history)
            LogsTab()
                .tabItem { Label("Logs", systemImage: "terminal.fill") }
                .tag(Tab.logs)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(themeManager.theme.accent)
        .environment(\.theme, themeManager.theme)
        .environmentObject(model)
        .environmentObject(themeManager)
        .environmentObject(router)
        .sheet(item: Binding(get: { model.pendingApprovals.first }, set: { _ in })) { pending in
            ReviewSheet(pending: pending, model: model, remaining: model.pendingApprovals.count)
        }
        .sheet(item: Binding(get: { model.pendingConsents.first }, set: { _ in })) { pending in
            TaskConsentSheet(pending: pending, model: model, remaining: model.pendingConsents.count)
        }
        .preferredColorScheme(themeManager.theme.preferredColorScheme)
        .onAppear {
            LogStore.shared.start()
            model.start()
        }
    }
}

#Preview {
    ContentView()
}
