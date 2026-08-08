// APIServer/Migrations/BackfillDeclaredLanguage.swift
//
// One-time backfill so every assignment already on disk carries an ANSWER to
// "what language is this?", rather than leaving that to be re-derived forever.

import Core
import Fluent
import Foundation

/// Records a declared language on every existing test setup.
///
/// Declaring the language at creation is what lets the rest of the system stop
/// guessing: once `languageDeclared` is set, nil `language` means "the author
/// says this has no language" rather than "nobody has been asked", and a worker
/// can refuse a job it cannot identify instead of falling back to Python. That
/// only holds if EXISTING content carries the flag too — otherwise every
/// pre-existing assignment looks undeclared forever and the guessing paths can
/// never be removed.
///
/// The backfill is deterministic: it runs the same resolution the server runs
/// today (recorded language, then a graded script's extension, then the starter
/// notebook's kernel) and writes the answer down. An assignment that resolves to
/// nothing is recorded as declared-with-no-language, which is the truthful
/// answer for a plain `.sh` suite — the case that resolution has always returned
/// nothing for and that the system has always supported.
///
/// It is idempotent by construction: a setup that already carries
/// `languageDeclared` is skipped, so a re-run (or a revert-then-reapply) cannot
/// overwrite an author's later choice with a re-derived one.
struct BackfillDeclaredLanguage: ChickadeeMigration {

    func prepare(on database: Database) async throws {
        // A full model query is safe HERE specifically because this migration is
        // registered last, after every `Create*` — the #1077 hazard is a
        // migration full-querying a model whose columns a LATER migration adds.
        let setups = try await APITestSetup.query(on: database).all()
        var declared = 0
        var withoutLanguage = 0

        for setup in setups {
            guard let manifest = setup.decodedManifest() else { continue }
            // Already answered — by an author on the edit page, or by an earlier
            // run of this migration. Never re-derive over a real answer.
            guard manifest.languageDeclared != true else { continue }

            let resolved = AssignmentLanguage.resolve(for: setup, manifest: manifest)
            guard let updated = manifestWithDeclaredLanguage(setup.manifest, language: resolved)
            else { continue }
            setup.manifest = updated
            try await setup.save(on: database)

            declared += 1
            if resolved == nil { withoutLanguage += 1 }
        }

        database.logger.info(
            """
            backfill_declared_language: \(declared) test setup(s) stamped \
            (\(withoutLanguage) with no language, i.e. shell-script suites)
            """)
    }

    /// Deliberately a no-op rather than stripping the field.
    ///
    /// Reverting would put every assignment back to undeclared, which is not the
    /// state it was in before — an author may have declared a language through
    /// the edit page since. There is nothing to undo: the flag records that the
    /// question has an answer, and it does.
    func revert(on database: Database) async throws {}

    /// Rewrites the manifest JSON with `languageDeclared` set, and `language`
    /// set or removed to match `language`.
    ///
    /// Works on the raw JSON rather than re-encoding a decoded `TestProperties`,
    /// so a manifest carrying fields this build does not know keeps them. A
    /// round-trip through the type would silently drop anything newer, which on
    /// a rollback would mean the migration ate content the newer build wrote.
    private func manifestWithDeclaredLanguage(
        _ manifestJSON: String, language: AssignmentLanguage?
    ) -> String? {
        guard
            var dict = (try? JSONSerialization.jsonObject(with: Data(manifestJSON.utf8)))
                as? [String: Any]
        else { return nil }
        dict["languageDeclared"] = true
        if let language {
            dict["language"] = language.rawValue
        } else {
            dict.removeValue(forKey: "language")
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys])
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
