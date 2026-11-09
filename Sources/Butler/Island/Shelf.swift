import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files held at the notch. The shelf keeps a reference to each file, not a copy, so nothing is moved or duplicated
/// on disk. Things dropped that are not files yet (an image dragged from a web page) are saved to Butler's own folder.
struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()
    var owned = false   // true when Butler created the file (dropped image data), so Butler may delete it later
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

@MainActor
final class Shelf: ObservableObject {
    static let shared = Shelf()

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbs: [UUID: NSImage] = [:]

    private let file: URL
    let holding: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Butler")
        holding = dir.appendingPathComponent("Shelf")
        try? FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("shelf.json")
        if let d = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ShelfItem].self, from: d) {
            var seen = Set<String>()
            items = saved.compactMap { item in
                var item = item
                item.path = Self.canonical(item.url)
                guard FileManager.default.fileExists(atPath: item.path), seen.insert(item.path).inserted else { return nil }
                return item
            }
        }
        items.forEach(makeThumb)
        save()   // writes back the cleaned-up list
    }

    func add(_ urls: [URL], owned: Bool = false) {
        var changed = false
        for u in urls where u.isFileURL {
            let path = Self.canonical(u)
            guard !items.contains(where: { $0.path == path }) else { continue }
            let item = ShelfItem(path: path, owned: owned)
            items.insert(item, at: 0)
            makeThumb(item)
            changed = true
        }
        if changed { save() }
    }

    /// One spelling per file: /tmp and /private/tmp, or a symlink and its target, are the same file.
    static func canonical(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }

    func remove(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), item.owned { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll { $0.id == id }
        thumbs[id] = nil
        save()
    }

    func clear() { items.map(\.id).forEach(remove) }

    /// Puts the file on the clipboard. Paste it in Finder to copy it there, or into a chat or upload box.
    func copy(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
    }

    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    // MARK: Dropping in

    /// Accepts files, and images that are not files yet (saved into Butler's shelf folder).
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { Shelf.shared.add([url]) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                let name = (p.suggestedName ?? "Image \(Int(Date().timeIntervalSince1970))")
                // Read the file type now: the provider itself cannot be handed to the loading thread.
                let type = p.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: .image) }
                let ext = type?.preferredFilenameExtension ?? "png"
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let shelf = Shelf.shared
                            var dest = shelf.holding.appendingPathComponent(name).appendingPathExtension(ext)
                            if FileManager.default.fileExists(atPath: dest.path) {
                                dest = shelf.holding.appendingPathComponent("\(name) \(UUID().uuidString.prefix(4))").appendingPathExtension(ext)
                            }
                            if (try? data.write(to: dest)) != nil { shelf.add([dest], owned: true) }
                        }
                    }
                }
            }
        }
        return took
    }

    // MARK: Private

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file, options: .atomic) }
    }

    private func makeThumb(_ item: ShelfItem) {
        thumbs[item.id] = NSWorkspace.shared.icon(forFile: item.path)
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 128, height: 128),
                                               scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Shelf.shared.thumbs[id] = img } }
        }
    }
}

// MARK: Dragging out

/// Lets a shelf item be dragged into Finder, a browser, a chat or any app. Offers a copy only, so dropping into a Finder
/// folder copies the file instead of moving it, which a plain Finder drag on the same disk would do.
struct DragOut: NSViewRepresentable {
    var item: ShelfItem
    var image: NSImage?
    func makeNSView(context: Context) -> DragOutView { DragOutView() }
    func updateNSView(_ v: DragOutView, context: Context) { v.url = item.url; v.image = image }
}

final class DragOutView: NSView, NSDraggingSource {
    var url: URL?
    var image: NSImage?
    private var start: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // the island panel never becomes key
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        start = nil
        if event.clickCount == 2, let url { NSWorkspace.shared.open(url) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let s = start else { return }
        let p = event.locationInWindow
        guard hypot(p.x - s.x, p.y - s.y) > 3 else { return }
        start = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image ?? NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
