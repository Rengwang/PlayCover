#!/usr/bin/env python3
"""Test the production alias methods against an isolated filesystem fixture."""
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
source = (repo / 'PlayCover/Utils/Extensions/PlayAppExtensions.swift').read_text()
methods = source[source.index('    func createAlias()'):source.rfind('\n}')]
extensions = (repo / 'PlayCover/Utils/Extensions/URLExtensions.swift').read_text()
start = extensions.index('    func enumerateContents(')
enumeration = extensions[start:extensions.index('    func appendingEscapedPathComponent', start)]
support = r'''
import Foundation
class Log { static let shared = Log(); func log(_ value: String) { print(value) } }
class AppInfo { let executableName = "Main" }
class PlayApp {
    let url: URL, aliasURL: URL
    let info = AppInfo()
    init(_ root: URL) { url = root.appendingPathComponent("Source.app"); aliasURL = root.appendingPathComponent("Alias.app") }
}
extension FileManager { func delete(at url: URL) { try? removeItem(at: url) } }
'''
checks = r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let manager = FileManager.default, app = PlayApp(root)
try manager.createDirectory(at: app.url, withIntermediateDirectories: true)
for name in ["Info.plist", "Main", "Asset"] { try Data(name.utf8).write(to: app.url.appendingPathComponent(name)) }
app.ensureAliasIfNeeded()
let info = app.aliasURL.appendingPathComponent("Info.plist")
let original = (try manager.attributesOfItem(atPath: info.path))[.systemFileNumber] as! NSNumber
app.ensureAliasIfNeeded()
let unchanged = (try manager.attributesOfItem(atPath: info.path))[.systemFileNumber] as! NSNumber
precondition(original == unchanged, "Warm alias was rebuilt")
let added = app.url.appendingPathComponent("New.lproj")
try manager.createDirectory(at: added, withIntermediateDirectories: false)
app.ensureAliasIfNeeded()
let link = app.aliasURL.appendingPathComponent("New.lproj")
let firstDestination = try manager.destinationOfSymbolicLink(atPath: link.path)
precondition(URL(fileURLWithPath: firstDestination).resolvingSymlinksInPath().path == added.resolvingSymlinksInPath().path)
let withDirectory = (try manager.attributesOfItem(atPath: info.path))[.systemFileNumber] as! NSNumber
app.ensureAliasIfNeeded()
precondition(withDirectory == ((try! manager.attributesOfItem(atPath: info.path))[.systemFileNumber] as! NSNumber),
             "Warm alias with a directory was rebuilt")
try manager.removeItem(at: app.url.appendingPathComponent("Asset"))
app.ensureAliasIfNeeded()
precondition(!manager.fileExists(atPath: app.aliasURL.appendingPathComponent("Asset").path))
try manager.removeItem(at: link)
try manager.createSymbolicLink(at: link, withDestinationURL: app.url.appendingPathComponent("Info.plist"))
app.ensureAliasIfNeeded()
let repairedDestination = try manager.destinationOfSymbolicLink(atPath: link.path)
precondition(URL(fileURLWithPath: repairedDestination).resolvingSymlinksInPath().path == added.resolvingSymlinksInPath().path)
print("PASS unchanged alias reused; added/removed resources and wrong resource links repaired")
'''
with tempfile.TemporaryDirectory(prefix='playcover-alias-test-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(support + '\nextension URL {\n' + enumeration +
                                   '\n}\nextension PlayApp {\n' + methods + '\n}\n' + checks)
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe'), str(work / 'fixture')], check=True)
