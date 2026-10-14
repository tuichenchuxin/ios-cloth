import SwiftUI
import SwiftData

struct RootTabView: View {
    var body: some View {
        TabView {
            OutfitTabView()
                .tabItem { Label("搭配", systemImage: "sparkles") }

            ClosetView()
                .tabItem { Label("衣柜", systemImage: "tshirt") }

            SavedOutfitsView()
                .tabItem { Label("我的搭配", systemImage: "heart") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
