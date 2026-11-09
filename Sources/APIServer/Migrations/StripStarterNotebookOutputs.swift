// APIServer/Migrations/StripStarterNotebookOutputs.swift
//
// One-time cleanup: clears the cell outputs from every stored starter
// notebook. From this release on, each write of a starter notebook clears them
// (`starterNotebookForStorage`); this migration cleans the notebooks written
// before that, so students run each cell themselves instead of opening the
// author's results.
//
// A data migration with a file side effect: the starter notebook is the flat
// `.ipynb` at `test_setups.notebook_path`, not a column. Only that file is
// rewritten, and only when it holds something to clear, so a clean notebook
// keeps its bytes and mtime. Setups with no flat file (a notebook only inside
// the setup zip) are covered on read: `resolveNotebook` clears outputs from a
// zip-extracted starter.
//
// Untouched on purpose: the solution notebook (staff-facing; how a revealed
// solution reaches students is its own question), and every student's working
// copy (their own work, which may hold their own outputs). A student who opened
// the assignment before this ran keeps the copy they were given.
//
// A file that cannot be read or written is logged and skipped: a cleanup must
// not stop the server from booting. On a fresh database it touches no rows.

import Fluent
import Foundation

struct StripStarterNotebookOutputs: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        let setups = try await APITestSetup.query(on: database)
            .filter(\.$notebookPath != nil)
            .all()
        var cleared = 0
        for setup in setups {
            guard let path = setup.notebookPath else { continue }
            let url = URL(fileURLWithPath: path)
            // Blocking file I/O in an async migration: it runs once, at boot,
            // before the server takes requests.
            do {
                let original = try Data(contentsOf: url)
                let stripped = NotebookOutputs.stripped(original)
                guard stripped != original else { continue }
                try stripped.write(to: url, options: .atomic)
                cleared += 1
            } catch {
                database.logger.warning(
                    "starter_outputs_not_cleared setup=\(setup.id ?? "unknown") reason=\(error)")
            }
        }
        database.logger.info("starter_outputs_cleared count=\(cleared) of=\(setups.count)")
    }

    /// Nothing to restore: the cleared outputs were never authored content.
    func revert(on database: any Database) async throws {}
}
