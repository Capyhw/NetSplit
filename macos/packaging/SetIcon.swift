import AppKit

guard CommandLine.argc >= 3 else {
    fputs("usage: SetIcon <icon> <file>\n", stderr)
    exit(1)
}
let iconPath = CommandLine.arguments[1]
let targetPath = CommandLine.arguments[2]
guard let image = NSImage(contentsOfFile: iconPath) else {
    fputs("cannot read icon\n", stderr)
    exit(2)
}
let ok = NSWorkspace.shared.setIcon(image, forFile: targetPath, options: [])
exit(ok ? 0 : 3)
