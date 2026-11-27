// Bookmarks for the DMG's background picture (scripts/make-dmg.sh). Finder finds a DMG window's background through
// a bookmark (.DS_Store record pBBk, matched by the volume's UUID) before the alias in icvp (matched by the volume's
// name), so two Transcribe DMGs mounted at once each show their own picture.
//
//   xcrun swift scripts/dmg-bookmark.swift create <file> <out>   writes a bookmark to <file> into <out>
//   xcrun swift scripts/dmg-bookmark.swift resolve <bookmark>     prints the path it resolves to now
//
// The bookmark is minimal and carries no sandbox extension. Like the one Finder writes, it also names the image it
// was made in (a temporary file on the build Mac) and that Mac's startup volume. Exit: 0 done; 1 failed; 2 usage.
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (4, "create"):
    do {
        let data = try URL(fileURLWithPath: args[2]).bookmarkData(
            options: [.minimalBookmark, .withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try data.write(to: URL(fileURLWithPath: args[3]))
    } catch {
        fail("error: could not make a bookmark to \(args[2]): \(error)", 1)
    }
case (3, "resolve"):
    do {
        var stale = false
        let url = try URL(resolvingBookmarkData: Data(contentsOf: URL(fileURLWithPath: args[2])),
                          options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        print(url.path)
    } catch {
        fail("error: the bookmark does not resolve: \(error)", 1)
    }
default:
    fail("usage: dmg-bookmark.swift create <file> <out> | resolve <bookmark>", 2)
}
