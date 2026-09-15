import SwiftUI

struct StackDetailView: View {
    @EnvironmentObject private var store: StackStore
    @Environment(\.dismiss) private var dismiss

    let stack: PhotoStack
    @State private var selectedID: String
    @State private var isDeleting = false
    @State private var errorMessage: String?

    init(stack: PhotoStack) {
        self.stack = stack
        _selectedID = State(initialValue: stack.topPick.id)
    }

    private var currentStack: PhotoStack {
        store.stacks.first(where: { $0.id == stack.id }) ?? stack
    }

    private var selectedItem: PhotoItem? {
        currentStack.items.first(where: { $0.id == selectedID }) ?? currentStack.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let selectedItem {
                AssetImage(source: selectedItem.source, maxDimension: 1400)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
                    .overlay(alignment: .topLeading) { badge(for: selectedItem) }
            }

            if let selectedItem, let breakdown = selectedItem.breakdown {
                Divider()
                AttributeBar(
                    breakdown: breakdown,
                    distanceToTop: selectedItem.distanceToTop,
                    isTopPick: selectedItem.id == currentStack.topPick.id
                )
            }

            Divider()
            filmstrip
            Divider()
            actionBar
        }
        .frame(width: 820, height: 680)
        .alert("Couldn't delete", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            Text("\(currentStack.count) similar photos")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding()
    }

    private func badge(for item: PhotoItem) -> some View {
        Group {
            if item.id == currentStack.topPick.id {
                Label("Top pick", systemImage: "star.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.yellow.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(12)
            }
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(currentStack.items) { item in
                    AssetImage(source: item.source, maxDimension: 200)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(item.id == selectedID ? Color.accentColor : .clear, lineWidth: 3)
                        )
                        .overlay(alignment: .topTrailing) {
                            if item.id == currentStack.topPick.id {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                    .padding(4)
                            }
                        }
                        .onTapGesture { selectedID = item.id }
                }
            }
            .padding()
        }
        .frame(height: 116)
    }

    private var actionBar: some View {
        HStack {
            // A folder scan has nothing to delete through: the app only ever
            // deletes via PhotoKit, which moves photos to Recently Deleted.
            // Removing files from someone's disk is a different promise, and
            // this app does not make it.
            if !currentStack.isDeletable {
                Label("Folder scan — nothing here is modified", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let name = selectedItem?.source.displayName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if let selectedItem, selectedItem.id != currentStack.topPick.id {
                    Button(role: .destructive) {
                        delete([selectedItem.id])
                    } label: { Label("Delete this", systemImage: "trash") }
                }
                Spacer()
                Button {
                    let rest = Set(currentStack.others.map(\.id))
                    delete(rest)
                } label: {
                    Label("Keep top pick, delete \(currentStack.count - 1) others", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentStack.count < 2)
            }
        }
        .padding()
        .overlay { if isDeleting { ProgressView() } }
    }

    private func delete(_ ids: Set<String>) {
        let assets = currentStack.items
            .filter { ids.contains($0.id) }
            .compactMap(\.source.asset)
        guard !assets.isEmpty else { return }
        isDeleting = true
        Task {
            do {
                try await PhotoLibrary.delete(assets)
                store.removeItems(ids, from: currentStack)
                isDeleting = false
                if store.stacks.first(where: { $0.id == stack.id }) == nil {
                    dismiss()
                } else {
                    selectedID = currentStack.topPick.id
                }
            } catch {
                isDeleting = false
                // User cancelling the system delete prompt also surfaces here; keep it quiet-ish.
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Compact strip explaining the selected photo's best-shot score.
struct AttributeBar: View {
    let breakdown: ScoreBreakdown
    var distanceToTop: Double?
    var isTopPick: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if isTopPick {
                chip("Top pick", "", .yellow)
            } else if let d = distanceToTop {
                // Lower distance = more visually similar to the top pick.
                chip("Distance to top", String(format: "%.2f", d), d < 0.4 ? .green : (d < 0.7 ? .orange : .red))
            }
            chip("Score", String(format: "%.2f", breakdown.total), .accentColor)
            chip("Aesthetic", String(format: "%.0f%%", breakdown.aesthetic * 100), .blue)

            if breakdown.faceCount > 0 {
                chip("\(breakdown.faceCount) face\(breakdown.faceCount > 1 ? "s" : "")", "", .gray)
                chip("Face quality", String(format: "%.0f%%", breakdown.faceQuality * 100), .teal)
                chip(
                    breakdown.eyesOpen >= 0.999 ? "Eyes open" : "Eyes",
                    String(format: "%.0f%%", breakdown.eyesOpen * 100),
                    breakdown.eyesOpen >= 0.999 ? .green : .orange
                )
                chip("Smiling", String(format: "%.0f%%", breakdown.smiling * 100), breakdown.smiling > 0 ? .green : .gray)
            } else if breakdown.isUtility {
                chip("Screenshot / document", "", .orange)
            } else {
                chip("No faces", "", .gray)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func chip(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            if !value.isEmpty { Text(value).fontWeight(.semibold) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
    }
}
