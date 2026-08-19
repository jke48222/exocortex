// Test helper: put an item on the pasteboard with a given marker type.
// usage: set_pasteboard <marker-type|none> <string>
import AppKit
let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 2 else { print("usage: set_pasteboard <marker|none> <string>"); exit(2) }
let pb = NSPasteboard.general
pb.clearContents()
var types: [NSPasteboard.PasteboardType] = [.string]
if a[0] != "none" { types.insert(NSPasteboard.PasteboardType(a[0]), at: 0) }
pb.declareTypes(types, owner: nil)
pb.setString(a[1], forType: .string)
if a[0] != "none" { pb.setString("", forType: NSPasteboard.PasteboardType(a[0])) }
print("pasteboard set: marker=\(a[0])")
