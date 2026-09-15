import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: StackStore
    @State private var selectedStack: PhotoStack?
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)]

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                placeholder(
                    icon: "square.stack.3d.up",
                    title: "Find your photo stacks",
                    message: "Scan your Photos library — or point “Scan Folder…” at a folder on disk — to group near-identical shots and surface the best one from each."
                )
            case .denied:
                placeholder(
                    icon: "lock.fill",
                    title: "Photos access needed",
                    message: "Enable Photos access for Featured Photo in System Settings ▸ Privacy & Security ▸ Photos."
                )
            case .scanning(let progress, let note):
                VStack(spacing: 16) {
                    ProgressView(value: progress) { Text(note) }
                        .frame(maxWidth: 360)
                    Text("\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done:
                stackGrid
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Stacking settings")
                Button {
                    if let folder = chooseFolder() {
                        Task { await store.scanFolder(folder) }
                    }
                } label: {
                    Label("Scan Folder…", systemImage: "folder")
                }
                .help("Group photos in a folder on disk instead of the Photos library")
                .disabled(isScanning)
                Button {
                    Task { await store.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .help("Scan the Photos library")
                .disabled(isScanning)
            }
        }
        .popover(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(item: $selectedStack) { stack in
            StackDetailView(stack: stack).environmentObject(store)
        }
        .navigationTitle("Featured Photo")
    }

    private var isScanning: Bool {
        if case .scanning = store.phase { return true }
        return false
    }

    /// The open panel is also what grants a sandboxed app access to the folder:
    /// the entitlement is `files.user-selected.read-only`, so nothing outside
    /// what the user picks here is readable.
    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder of photos to group. Nothing in it is modified."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private var stackGrid: some View {
        Group {
            if store.stacks.isEmpty {
                placeholder(
                    icon: "checkmark.circle",
                    title: "No stacks found",
                    message: emptyMessage
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.stacks) { stack in
                            StackCard(stack: stack)
                                .onTapGesture { selectedStack = stack }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    /// The "nothing found" text has to name the right source — telling someone
    /// who scanned a folder about their scan limit would just be confusing.
    private var emptyMessage: String {
        let tail = "Try widening the time window or raising the similarity threshold in settings."
        switch store.origin {
        case .library:
            return "No near-identical bursts in the most recent \(store.config.scanLimit) photos. \(tail)"
        case .folder(let url):
            return "No near-identical bursts in “\(url.lastPathComponent)”. \(tail)"
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StackCard: View {
    let stack: PhotoStack

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)   // square sized to the cell width
                    .overlay { AssetImage(source: stack.topPick.source) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Label("\(stack.count)", systemImage: "square.stack.3d.up.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            Text(stack.date, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StackStore

    var body: some View {
        Form {
            Section("Stacking") {
                VStack(alignment: .leading) {
                    Text("Time window: \(Int(store.config.timeWindow))s")
                    Slider(value: $store.config.timeWindow, in: 2...60, step: 1)
                    Text("Max gap between shots in the same session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Similarity threshold: \(store.config.similarityThreshold, specifier: "%.2f")")
                    Slider(value: $store.config.similarityThreshold, in: 0.2...1.5, step: 0.05)
                    Text("Lower = stricter (more identical). Higher groups looser matches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Scan limit: \(store.config.scanLimit) photos")
                    Slider(value: Binding(
                        get: { Double(store.config.scanLimit) },
                        set: { store.config.scanLimit = Int($0) }
                    ), in: 100...3000, step: 100)
                }
                VStack(alignment: .leading) {
                    Toggle("Same camera only", isOn: $store.config.requireSameCamera)
                    Text("Never group photos from different cameras (EXIF make/model/lens).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 320)
    }
}
