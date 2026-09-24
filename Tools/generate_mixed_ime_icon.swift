import AppKit

// Native text icon for the macOS input menu. No application/user preferences are read.
let image = NSImage(size: NSSize(width: 18, height: 18))
image.lockFocus()
let title = "自" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black]
let size = title.size(withAttributes: attributes)
title.draw(at: NSPoint(x: (18 - size.width) / 2, y: (18 - size.height) / 2), withAttributes: attributes)
image.unlockFocus()
try image.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
