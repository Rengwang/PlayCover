#!/usr/bin/env python3
"""Exercise the production Mach-O reader against thin/FAT64 and repair fixtures.

Requires macOS and Xcode. All generated binaries stay in a temporary directory.
"""
import plistlib
import struct
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
missing = '/System/iOSSupport/System/Library/Frameworks/PlayCoverInspectionMissing.framework/PlayCoverInspectionMissing'


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


with tempfile.TemporaryDirectory(prefix='playcover-inspection-') as directory:
    work = Path(directory)
    (work / 'library.c').write_text('int inspection_value(void) { return 0; }\n')
    (work / 'main.c').write_text('extern int inspection_value(void); int main(void) { return inspection_value(); }\n')
    (work / 'plain.c').write_text('int main(void) { return 0; }\n')
    target = 'arm64-apple-ios15.0-macabi'
    run('/usr/bin/xcrun', 'clang', '-target', target, '-dynamiclib', work / 'library.c',
        '-Wl,-install_name,' + missing, '-o', work / 'Library.dylib')
    for name, flag in [('strong', '-needed_library'), ('weak', '-weak_library')]:
        app = work / (name + '.app')
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Main'}))
        run('/usr/bin/xcrun', 'clang', '-target', target, work / 'main.c',
            '-Xlinker', flag, '-Xlinker', work / 'Library.dylib', '-o', app / 'Main')
    run('/usr/bin/xcrun', 'clang', '-target', 'x86_64-apple-ios15.0-macabi', work / 'plain.c', '-o', work / 'x86')
    fat = work / 'fat64.app'
    fat.mkdir()
    (fat / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Main'}))
    run('/usr/bin/lipo', '-create', '-fat64', work / 'strong.app/Main', work / 'x86', '-output', fat / 'Main')

    # A minimal load-command-only image: segment and section data remain untouched by the rename.
    segment = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__RESTRICT', 0, 0, 0, 0, 1, 1, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__restrict', b'__RESTRICT', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, len(segment + section), 0, 0)
    (work / 'restrict').write_bytes(header + segment + section + bytes(4096))
    version = struct.pack('<IIIIII', 0x32, 24, 6, 11 << 16, 14 << 16, 0)
    sdk_header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, len(version), 0, 0)
    (work / 'sdk').write_bytes(sdk_header + version)
    (work / 'sdk').chmod(0o755)

    support = r'''
import Foundation
enum PlayCoverError: Error { case appCorrupted, appEncrypted, failedToStripBinary }
extension Dictionary {
    static func read(_ file: URL) throws -> Self? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? Self
    }
}
extension URL {
    func setBinaryPosixPermissions(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
enum Shell {
    static func run(print: Bool = true, _ path: String, _ args: String...) throws -> String {
        fatalError("The inspection fixture must not start another process")
    }
}
'''
    main = r'''
import Foundation
func check(_ passed: Bool, _ name: String) { precondition(passed, name); print("PASS " + name) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = CommandLine.arguments[2]
for name in ["strong", "fat64"] {
    let app = root.appendingPathComponent(name + ".app")
    let missing = Macho.firstUnavailableHostLibrary(app.appendingPathComponent("Main"), in: app)
    check(missing?.path == expected, name + " mandatory dependency remains visible")
}
let weak = root.appendingPathComponent("weak.app")
check(Macho.firstUnavailableHostLibrary(weak.appendingPathComponent("Main"), in: weak) == nil,
      "optional framework is not promoted to a launch failure")
let image = root.appendingPathComponent("strong.app/Main")
let data = try Data(contentsOf: image)
let header = data.extract(mach_header_64.self)
let commands = Data(data.prefix(MemoryLayout<mach_header_64>.size + Int(header.sizeofcmds)))
let end = try Macho.iterateLoadCommands(binary: commands) { _, _ in false }
check(end == commands.count, "a complete load-command buffer may end at EOF")
do {
    _ = try Macho.iterateLoadCommands(binary: Data(commands.dropLast())) { _, _ in false }
    fatalError("Truncated command buffer accepted")
} catch PlayCoverError.appCorrupted { print("PASS truncated command buffer rejected") }
let restricted = root.appendingPathComponent("restrict")
check(try Macho.stripRestrictSegment(atURL: restricted), "mapped restrict repair changes the image")
let revised = try Data(contentsOf: restricted)
check(try !Macho.stripRestrictSegment(atURL: restricted), "mapped restrict repair is idempotent")
check(revised == (try Data(contentsOf: restricted)), "unchanged inspection preserves bytes")
check(revised.range(of: Data("__RESTRICT".utf8)) == nil && revised.range(of: Data("__restrict".utf8)) == nil,
      "both segment and section names were repaired")
let sdk = root.appendingPathComponent("sdk")
check(try Macho.restoreApplicationSDK(at: sdk, sdkName: "iphoneos27.1"), "mapped SDK restoration succeeds")
check(try !Macho.restoreApplicationSDK(at: sdk, sdkName: "iphoneos27.1"), "SDK restoration is idempotent")
let mode = try FileManager.default.attributesOfItem(atPath: sdk.path)[.posixPermissions] as? Int
check(mode == 0o755, "SDK restoration preserves executable permissions")
'''
    (work / 'Support.swift').write_text(support)
    (work / 'main.swift').write_text(main)
    run('/usr/bin/xcrun', 'swiftc', '-O', '-suppress-warnings', work / 'Support.swift', work / 'main.swift',
        repo / 'PlayCover/Utils/Macho.swift', repo / 'PlayCover/Utils/Extensions/DataExtensions.swift',
        '-o', work / 'probe')
    run(work / 'probe', work, missing.removeprefix('/System/iOSSupport'))
