//
//  ContentView.swift
//  wurstfinger
//
//  Created by Claas Flint on 24.10.25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            #if os(iOS)
            OnboardingView()
                .tabItem {
                    Label("Setup", systemImage: "list.number")
                }

            TestAreaView()
                .tabItem {
                    Label("Test", systemImage: "keyboard")
                }
            #else
            // No Settings app to enable the keyboard in, and the system
            // keyboard can't be swapped out: the Mac build hosts the live
            // keyboard in-process instead.
            MacTestAreaView()
                .tabItem {
                    Label("Test", systemImage: "keyboard")
                }
            #endif

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#if !WURSTFINGER_NO_PREVIEWS
#Preview {
    ContentView()
}
#endif
