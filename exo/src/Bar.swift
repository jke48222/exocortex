import Foundation
import AppKit
import Carbon.HIToolbox

/// The everything-bar.
///
/// Phase 0's whole premise was: run it for two weeks and answer honestly, *did you search
/// it?* Every dead life-log in PASS-4 Area A died on that answer, and a CLI biases it —
/// friction is the independent variable. So the interface is the feature.
///
/// Design follows the Area I rules derived from the Remembrance Agent (1996) and the
/// autocomplete post-mortem: **ignoring must be free** (Esc, or click away), it **never
/// steals focus** (non-activating panel, so your cursor stays where it was), it does not
/// rearrange the environment, and **the one-line result IS the product** — Rhodes found
/// that seeing the one-liner usually triggers the memory without opening anything.
final class BarController: NSObject, NSTextFieldDelegate {
    let store: Store
    var panel: NSPanel!
    var field: NSTextField!
    var table: NSTableView!
    var rows: [Store.Hit] = []
    var debounce: Timer?

    init(store: Store) { self.store = store; super.init() }

    func build() {
        let w: CGFloat = 720, h: CGFloat = 420
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true; blur.layer?.cornerRadius = 12; blur.layer?.masksToBounds = true
        panel.contentView = blur

        field = NSTextField(frame: NSRect(x: 16, y: h - 52, width: w - 32, height: 34))
        field.placeholderString = "search your memory…"
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = self
        field.autoresizingMask = [.width, .minYMargin]
        blur.addSubview(field)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: w - 16, height: h - 68))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        table = NSTableView(frame: scroll.bounds)
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowHeight = 46
        table.selectionHighlightStyle = .regular
        let col = NSTableColumn(identifier: .init("c"))
        col.width = w - 40
        table.addTableColumn(col)
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        blur.addSubview(scroll)
        panel.center()
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }
    func show() {
        panel.center()
        panel.orderFrontRegardless()
        // key without activating the app: the caller's focus is never taken
        panel.makeKey()
        panel.makeFirstResponder(field)
    }
    func hide() { panel.orderOut(nil) }

    func controlTextDidChange(_ obj: Notification) {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.runSearch()
        }
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }   // Esc = free
        return false
    }

    func runSearch() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { rows = []; table.reloadData(); return }
        // FTS5 needs bare terms; treat input as a prefix-AND query
        let terms = q.split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }
                     .filter { !$0.isEmpty }.map { "\($0)*" }
        guard !terms.isEmpty else { return }
        rows = store.search(terms.joined(separator: " "), limit: 40, minTrust: nil)
        table.reloadData()
    }
}

extension BarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let h = rows[row]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: t.bounds.width, height: 46))
        // one line of content — the cue is the product
        let main = NSTextField(labelWithString: h.snip.isEmpty ? h.title
                                : h.snip.replacingOccurrences(of: "\n", with: " "))
        main.font = .systemFont(ofSize: 13)
        main.lineBreakMode = .byTruncatingTail
        main.frame = NSRect(x: 10, y: 22, width: t.bounds.width - 20, height: 18)
        v.addSubview(main)
        // provenance line — source, trust, when. Area H: injected/surfaced memory always
        // carries provenance so it can be audited and trusted appropriately.
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        let when = f.string(from: Date(timeIntervalSince1970: Double(h.ts) / 1_000_000))
        let sub = NSTextField(labelWithString: "\(h.source)  ·  \(h.trust)  ·  \(h.app)  ·  \(when)")
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = h.trust == "self" ? .systemGreen
                       : (h.trust == "untrusted" ? .secondaryLabelColor : .systemOrange)
        sub.frame = NSRect(x: 10, y: 5, width: t.bounds.width - 20, height: 14)
        v.addSubview(sub)
        return v
    }
}
