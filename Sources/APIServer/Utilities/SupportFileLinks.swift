// APIServer/Utilities/SupportFileLinks.swift
//
// The filesystem half of the working-copy link pass
// (`createSupportFileSymlinks`): link each support file from a setup's shared
// extraction into a student's JupyterLite folder. Which names to link is
// `StudentWorkspaceFiles.linkedSupportFiles`.

import Foundation

/// One support file the link pass could not link.
struct SupportFileLinkFailure: Equatable {
    let name: String
    let reason: String
}

/// Links each of `names` from `sharedDirectory` into `studentDirectory`, and
/// returns the ones it could not link, for the caller to log.
///
/// - A name in a subfolder (`data/patients.csv`) gets its parent folders made
///   first. The shared extraction already holds it at the same relative path.
/// - A folder entry (a name ending in `/`) is skipped. Linking it would hand
///   the student the whole shared folder.
/// - A name that the shared folder does not hold yet is skipped quietly, and
///   no folder is made for it.
/// - Anything already at the destination is kept, a link whose target is gone
///   included, so the pass is idempotent and a dataset written as a real file
///   is never shadowed.
/// - A name that could reach outside the student folder (a leading `/` or a
///   `..` component) is refused and reported, because making its parent
///   folders would write outside that folder.
func linkSupportFiles(
    _ names: [String],
    sharedDirectory: String,
    studentDirectory: String
) -> [SupportFileLinkFailure] {
    let fm = FileManager.default
    var failures: [SupportFileLinkFailure] = []
    for name in names where !name.isEmpty && !name.hasSuffix("/") {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
            failures.append(SupportFileLinkFailure(name: name, reason: "path leaves the working-copy folder"))
            continue
        }
        let src = sharedDirectory + name
        let dest = studentDirectory + "/" + name
        guard fm.fileExists(atPath: src) else { continue }
        let linkAtDest = (try? fm.destinationOfSymbolicLink(atPath: dest)) != nil
        guard !linkAtDest, !fm.fileExists(atPath: dest) else { continue }
        do {
            let parent = URL(fileURLWithPath: dest).deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: dest, withDestinationPath: src)
        } catch {
            failures.append(SupportFileLinkFailure(name: name, reason: error.localizedDescription))
        }
    }
    return failures
}
