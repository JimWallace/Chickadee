// APIServer/Services/StudentDatasetDelivery.swift
//
// The dataset files one student receives in one assignment, made by the same
// call the worker and the editor make: `DatasetResolver.resolve` with the
// student's assignment seed, for a course-scoped dataset the course seed, and
// for a partition the student's deal number, over the setup's shared support
// directory
// (docs/datasets-course-library.md §4.6). The student's "my rows" download
// serves these bytes, so a student reads exactly what is graded.

import Core
import Fluent
import Foundation
import Vapor

enum StudentDatasetDelivery {

    /// The file `filename` as `userID` receives it in `assignment`, or nil
    /// when the manifest marks no dataset of that name.
    ///
    /// The seeds are issued on first use, as they are when the student first
    /// opens the editor or submits; the bytes never depend on which comes
    /// first.
    static func file(
        named filename: String, setup: APITestSetup, assignment: APIAssignment, userID: UUID,
        testSetupsDirectory: String, on db: any Database
    ) async throws -> String? {
        guard let manifest = setup.decodedManifest(), manifest.datasets.contains(where: { $0.file == filename }),
            let setupID = setup.id
        else { return nil }
        let seedHex = try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: try assignment.requireID(), on: db)
        let courseSeedHex = try await CourseSeedStore.seedIfNeeded(
            manifest: manifest, userID: userID, courseID: setup.courseID, on: db)
        let dealNumber = try await DatasetDeals.dealNumber(
            manifest: manifest, courseID: setup.courseID, assignmentID: try assignment.requireID(), userID: userID,
            on: db)

        let sharedDir = testSetupsDirectory + "shared/\(setupID)/"
        if !FileManager.default.fileExists(atPath: sharedDir + filename) {
            await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: testSetupsDirectory)
        }
        let files = try await runBlocking {
            DatasetResolver.resolve(
                manifest: manifest, seedHex: seedHex, courseSeedHex: courseSeedHex, dealNumber: dealNumber,
                sourceDirectory: sharedDir)
        }
        return DatasetDeals.withholdingUndealtParts(files, manifest: manifest, dealNumber: dealNumber)?[filename]
    }
}
