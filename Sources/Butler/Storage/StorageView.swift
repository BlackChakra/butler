import SwiftUI
import AppKit

struct StorageView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 22)

            if !model.fullDiskAccess { AccessNote().padding(.horizontal, 36).padding(.bottom, 14) }
            if !model.grew.isEmpty { GrewNote(items: model.grew).padding(.horizontal, 36).padding(.bottom, 14) }

            Divider().opacity(0.5)

            if model.spots.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "Looking at your Mac" : "Nothing large found")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26, pinnedViews: []) {
                        ForEach(Bucket.allCases) { bucket in
                            let items = model.spots.filter { $0.bucket == bucket }
                            if !items.isEmpty { BucketSection(model: model, bucket: bucket, items: items) }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
                }
            }

            Divider().opacity(0.5)
            Footer(model: model).padding(.horizontal, 36).padding(.vertical, 16)
        }
    }
}

// MARK: Header

private struct Header: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bytes(model.free))
                        .font(.system(size: 54, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.4), value: model.free)
                    Text("free of \(bytes(model.total))")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.scan) {
                    Text(model.busy ? "Scanning" : "Scan again")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain).disabled(model.busy)
            }
            StorageBar(model: model)
        }
    }
}

private struct StorageBar: View {
    @ObservedObject var model: Model

    var body: some View {
        let total = Double(max(model.total, 1))
        let used = Double(max(model.total - model.free, 0))
        let known = Bucket.allCases.map { ($0, Double(model.bucketTotal($0))) }
        let other = max(used - known.reduce(0) { $0 + $1.1 }, 0)

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(known, id: \.0.id) { b, v in
                        Rectangle().fill(b.tint).frame(width: geo.size.width * v / total)
                    }
                    Rectangle().fill(Color.primary.opacity(0.22)).frame(width: geo.size.width * other / total)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.5), value: model.spots.count)
            }
            .frame(height: 12)

            HStack(spacing: 16) {
                ForEach(known, id: \.0.id) { b, v in
                    if v > 0 { Legend(color: b.tint, text: b.title, value: Int64(v)) }
                }
                Legend(color: Color.primary.opacity(0.22), text: "Everything else", value: Int64(other))
            }
        }
    }
}

private struct Legend: View {
    var color: Color; var text: String; var value: Int64
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
            Text(bytes(value)).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

// MARK: Notes

private struct AccessNote: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text("Some folders are hidden from this app. Allow Full Disk Access to see everything.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct GrewNote: View {
    var items: [(name: String, delta: Int64)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Grew since the last scan", systemImage: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            ForEach(items.prefix(3), id: \.name) { i in
                HStack {
                    Text(i.name).font(.system(size: 13))
                    Spacer()
                    Text("+\(bytes(i.delta))").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.09)))
    }
}

// MARK: List

private struct BucketSection: View {
    @ObservedObject var model: Model
    var bucket: Bucket
    var items: [Spot]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: bucket.symbol).foregroundStyle(bucket.tint).font(.system(size: 13, weight: .semibold))
                Text(bucket.title).font(.system(size: 15, weight: .semibold))
                Text(bytes(model.bucketTotal(bucket))).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(bucket.blurb).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(items) { spot in
                    Row(model: model, spot: spot)
                    if spot.id != items.last?.id { Divider().padding(.leading, 34).opacity(0.5) }
                }
            }
        }
    }
}

private struct Row: View {
    @ObservedObject var model: Model
    var spot: Spot
    @State private var info = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name).font(.system(size: 14)).lineLimit(1)
                Text(spot.lockedReason ?? spot.detail)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(bytes(spot.frees))
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                if spot.shared > max(50_000_000, spot.size / 10) {
                    // Finder would show the bigger number. Say why cleaning gives back less.
                    Text("\(bytes(spot.size)) on disk, shared")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.orange)
                }
            }
            .help(spot.shared > 0 ? "Frees \(bytes(spot.frees)). \(bytes(spot.shared)) is shared with a copy elsewhere and stays on disk." : "Frees \(bytes(spot.frees))")
            Button { info.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $info, arrowEdge: .trailing) { Detail(model: model, spot: spot) }
        }
        .padding(.vertical, 9).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.toggle(spot) }
    }

    @ViewBuilder private var lead: some View {
        if spot.canClean {
            Image(systemName: model.selected.contains(spot.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(model.selected.contains(spot.id) ? spot.bucket.tint : Color.primary.opacity(0.25))
                .frame(width: 22)
        } else {
            Image(systemName: spot.lockedReason != nil ? "lock.fill" : "hand.point.up.left")
                .font(.system(size: 13)).foregroundStyle(.tertiary).frame(width: 22)
        }
    }
}

private struct Detail: View {
    @ObservedObject var model: Model
    var spot: Spot
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spot.name).font(.system(size: 14, weight: .semibold))
            Text(spot.detail).font(.system(size: 13)).foregroundStyle(.secondary)
            if let note = spot.note {
                Label(note, systemImage: "square.on.square").font(.system(size: 13)).foregroundStyle(.orange)
            }
            if let how = spot.howTo {
                Label(how, systemImage: "arrow.right.circle").font(.system(size: 13))
            } else if !spot.ifRemoved.isEmpty {
                Label(spot.ifRemoved, systemImage: "questionmark.circle").font(.system(size: 13))
                Label(spot.permanentByNature ? "Deleted straight away. It rebuilds itself."
                                              : "Moves to the Trash unless you turn that off.",
                      systemImage: spot.permanentByNature ? "trash" : "arrow.uturn.backward")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let p = spot.root ?? spot.paths.first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p]) }
                }
                if spot.lockedReason == "On your protected list" {
                    Button("Unprotect") {
                        if let path = Protect.paths.first(where: { p in (spot.paths + [spot.root].compactMap { $0 }).contains { $0.path == p || $0.path.hasPrefix(p + "/") } }) {
                            model.unprotect(path)
                        }
                    }
                } else if spot.bucket == .rebuildable || spot.bucket == .yours, spot.root != nil {
                    Button(spot.bucket == .yours ? "Protect this file" : "Protect this project") { model.protect(spot) }
                        .help("Butler will never offer to clean it, on this or any later scan.")
                }
            }
            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        .labelStyle(TopLabelStyle())
        .padding(16).frame(width: 330, alignment: .leading)
    }
}

private struct TopLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 16)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Footer

private struct Footer: View {
    @ObservedObject var model: Model
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 16) {
            Toggle("Use the Trash", isOn: $model.useTrash)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if case .done(_, let trashed) = model.phase, trashed > 0 {
                Button("Empty Trash", action: model.emptyTrash)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            }
            ProtectedButton(model: model)
            Spacer()
            Text(model.selectedSpots.isEmpty ? "Nothing selected" : "\(model.selectedSpots.count) selected")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button { confirm = true } label: {
                Text(model.selectedBytes > 0 ? "Clean \(bytes(model.selectedBytes))" : "Clean")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 9)
                    .background(Capsule().fill(Color.accentColor.opacity(model.selectedBytes > 0 && !model.busy ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedBytes == 0 || model.busy)
            .confirmationDialog("Clean \(bytes(model.selectedBytes))?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Clean") { model.clean() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(summary)
            }
        }
    }

    private var summary: String {
        let names = model.selectedSpots.prefix(4).map(\.name).joined(separator: ", ")
        let more = model.selectedSpots.count > 4 ? " and \(model.selectedSpots.count - 4) more" : ""
        return "\(names)\(more). " + (model.useTrash ? "Your own files go to the Trash. Caches are deleted because they rebuild." : "Everything is deleted straight away.")
    }
}

// MARK: Protected folders

/// The list of folders Butler must never touch. Each person keeps their own.
private struct ProtectedButton: View {
    @ObservedObject var model: Model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(model.protectedCount == 0 ? "Protected" : "Protected · \(model.protectedCount)", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .top) { ProtectedList(model: model) }
    }
}

private struct ProtectedList: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protected").font(.system(size: 14, weight: .semibold))
            Text("Butler never offers to clean anything inside these, including node_modules and big files.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let paths = Protect.paths
            if paths.isEmpty {
                Text("Nothing protected yet").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(paths, id: \.self) { p in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 16, height: 16)
                            Text(p.replacingOccurrences(of: Catalog.home.path, with: "~"))
                                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.unprotect(p) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).help("Stop protecting")
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            Button("Add Folder…") { pick() }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        .padding(16).frame(width: 340, alignment: .leading)
        .id(model.protectedCount)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Protect"
        panel.message = "Choose folders or files Butler must never clean."
        panel.directoryURL = Catalog.home
        if panel.runModal() == .OK { panel.urls.forEach(model.addProtected) }
    }
}
