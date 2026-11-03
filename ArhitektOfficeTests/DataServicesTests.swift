import XCTest
import SwiftData
@testable import ArhitektOffice

@MainActor final class DataServicesTests: XCTestCase {
    private var schema: Schema {
        Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self])
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    func testCroatianDictationRetainsSourceAndClassifiesExample() {
        let project = Project(name: "Kuća Cerje", number: "24-017")
        let text = "Kuća Cerje. Danas sam razgovarao s investitorom. Geodet će poslati podlogu u petak. Trebam nazvati statičara. Problem je što još nemamo vlasnički list."
        let draft = DictationParser.parse(text, projects: [project])
        XCTAssertEqual(draft.originalText, text)
        XCTAssertEqual(draft.projectID, project.id)
        XCTAssertTrue(draft.projectIsConfident)
        XCTAssertEqual(draft.items.count, 5)
        XCTAssertEqual(draft.items[3].category, .task)
        XCTAssertEqual(draft.items[4].category, .issue)
        XCTAssertEqual(draft.items[2].category, .note)
    }

    func testProjectMatchingRequiresUnambiguousWholeNameOrNumber() {
        let first = Project(name: "Kuća Cerje", number: "2024-17")
        let second = Project(name: "Kuća Cerje", number: "2024-18")
        XCTAssertNil(DictationParser.parse("Kuća Cerje.", projects: [first, second]).projectID)
        XCTAssertNil(DictationParser.parse("Novi zapis.", projects: [first]).projectID)
        XCTAssertEqual(DictationParser.parse("Kuca Cerje.", projects: [first]).projectID, first.id)
        XCTAssertEqual(DictationParser.parse("Projekt 2024-17.", projects: [first, second]).projectID, first.id)
        first.isArchived = true
        XCTAssertNil(DictationParser.parse("Kuća Cerje.", projects: [first]).projectID)
    }

    func testUnpunctuatedLinesAreAllRetainedAsEditableSuggestions() {
        let text = "Trebam nazvati geodeta\nNedostaje vlasnički list"
        let draft = DictationParser.parse(text, projects: [])
        XCTAssertEqual(draft.originalText, text)
        XCTAssertEqual(draft.items.map(\.text), ["Trebam nazvati geodeta", "Nedostaje vlasnički list"])
        XCTAssertEqual(draft.items.map(\.category), [.task, .issue])
    }

    func testPhaseChangesCreateHistoryOnlyWhenChanged() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let project = Project(name: "Projekt")
        context.insert(project)
        let changedAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.changePhase(to: .concept, at: changedAt)
        project.changePhase(to: .concept)
        try context.save()
        XCTAssertEqual(project.phase, .concept)
        XCTAssertEqual(project.phaseHistory.count, 2)
        XCTAssertEqual(project.phaseHistory.first(where: { $0.phase == .concept })?.changedAt, changedAt)
        XCTAssertEqual(project.lastActivity, changedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhaseChange>()), 2)
    }

    func testBackupRoundTripPreservesRelationshipsAndRepeatedImportIsIdempotent() throws {
        let source = try memoryContainer()
        let project = Project(name: "Kuća Cerje", number: "24-17", investor: "Investitor", location: "Cerje")
        source.mainContext.insert(project)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = ProjectTask(title: "Nazvati statičara", details: "Provjeriti podlogu", dueDate: due, priority: .high, project: project)
        task.status = .completed
        source.mainContext.insert(task)
        let issue = ProjectIssue(title: "Vlasnički list", details: "Još nije dostavljen", project: project)
        issue.status = .resolved
        issue.resolution = "Dokument je dostavljen."
        source.mainContext.insert(issue)
        source.mainContext.insert(ProjectNote(text: "Razgovor s investitorom", sourceTranscript: "Izvorni diktat.", project: project))
        project.changePhase(to: .main)
        project.isArchived = true
        try source.mainContext.save()
        let data = try BackupService.export(context: source.mainContext)

        let target = try memoryContainer()
        let result = try BackupService.importData(data, into: target.mainContext)
        XCTAssertEqual(result.projectCount, 1)
        XCTAssertEqual(result.itemCount, 3)
        let existing = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Project>()).first)
        existing.name = "Lokalno preimenovanje"
        existing.tasks.first?.title = "Lokalna izmjena zadatka"
        existing.tasks.first?.status = .open
        try target.mainContext.save()
        // Restoring matching IDs must update these same records, not duplicate
        // them or silently preserve stale content instead of the selected backup.
        _ = try BackupService.importData(data, into: target.mainContext)
        let imported = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(imported.id, project.id)
        XCTAssertEqual(imported.name, project.name)
        XCTAssertEqual(imported.tasks.count, 1)
        XCTAssertEqual(imported.tasks.first?.title, task.title)
        XCTAssertEqual(imported.tasks.first?.project?.id, imported.id)
        XCTAssertEqual(imported.tasks.first?.priority, .high)
        XCTAssertEqual(imported.tasks.first?.status, .completed)
        XCTAssertEqual(imported.tasks.first?.dueDate, due)
        XCTAssertTrue(imported.isArchived)
        XCTAssertEqual(imported.issues.first?.resolution, "Dokument je dostavljen.")
        XCTAssertEqual(imported.notes.first?.sourceTranscript, "Izvorni diktat.")
        XCTAssertEqual(imported.phaseHistory.count, 2)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<ProjectTask>()), 1)
    }

    func testInvalidImportDoesNotMutateExistingDatabase() throws {
        let container = try memoryContainer()
        let project = Project(name: "Sačuvaj me")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let valid = try BackupService.export(context: container.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        json["projects"] = projects + projects
        let invalid = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try BackupService.importData(invalid, into: container.mainContext))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(project.name, "Sačuvaj me")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testUnsupportedVersionAndUnknownEnumAreRejected() throws {
        let container = try memoryContainer()
        container.mainContext.insert(Project(name: "Projekt"))
        try container.mainContext.save()
        let data = try BackupService.export(context: container.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 999
        XCTAssertThrowsError(try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: container.mainContext))
        json["version"] = 1
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        projects[0]["phase"] = "Nepostojeća faza"
        json["projects"] = projects
        XCTAssertThrowsError(try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: container.mainContext))
    }

    func testImportRefusesToOverwritePendingEdits() throws {
        let container = try memoryContainer()
        let project = Project(name: "Projekt")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let data = try BackupService.export(context: container.mainContext)
        project.name = "Nespremljena izmjena"
        XCTAssertThrowsError(try BackupService.importData(data, into: container.mainContext))
        XCTAssertEqual(project.name, "Nespremljena izmjena")
    }

    func testEmptyTaskTitleIsRejectedWithoutReplacingUserData() throws {
        let container = try memoryContainer()
        let project = Project(name: "Postojeći projekt")
        container.mainContext.insert(project)
        container.mainContext.insert(ProjectTask(title: "Sačuvani zadatak", project: project))
        try container.mainContext.save()
        let data = try BackupService.export(context: container.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        var tasks = try XCTUnwrap(projects[0]["tasks"] as? [[String: Any]])
        tasks[0]["title"] = "   \n\t"
        projects[0]["tasks"] = tasks
        projects[0]["name"] = "Ova promjena ne smije biti primijenjena"
        json["projects"] = projects
        XCTAssertThrowsError(try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: container.mainContext))
        XCTAssertEqual(project.name, "Postojeći projekt")
        XCTAssertEqual(project.tasks.first?.title, "Sačuvani zadatak")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testMalformedAndOversizedBackupsCannotCreateRecords() throws {
        let container = try memoryContainer()
        XCTAssertThrowsError(try BackupService.importData(Data("{broken JSON".utf8), into: container.mainContext))
        let oversized = Data(repeating: 0x20, count: BackupService.maximumBytes + 1)
        XCTAssertThrowsError(try BackupService.importData(oversized, into: container.mainContext)) { error in
            guard let backupError = error as? BackupError, case .tooLarge = backupError else {
                return XCTFail("Očekivano je odbijanje prevelike datoteke")
            }
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ProjectTask>()), 0)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testDeletingOneProjectCascadesOnlyItsOwnChildren() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let deleted = Project(name: "Brisanje")
        let retained = Project(name: "Zadržani projekt")
        context.insert(deleted)
        context.insert(retained)
        context.insert(ProjectTask(title: "Obrisati zadatak", project: deleted))
        context.insert(ProjectIssue(title: "Obrisati problem", project: deleted))
        context.insert(ProjectNote(text: "Obrisati bilješku", project: deleted))
        context.insert(ProjectTask(title: "Zadržati zadatak", project: retained))
        deleted.changePhase(to: .concept)
        try context.save()
        context.delete(deleted)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectTask>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectIssue>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectNote>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhaseChange>()), 1)
        XCTAssertEqual(retained.tasks.first?.title, "Zadržati zadatak")
        XCTAssertEqual(retained.tasks.first?.project?.id, retained.id)
    }

    func testExistingChildCannotMoveToDifferentProjectThroughImport() throws {
        let container = try memoryContainer()
        let first = Project(name: "Prvi")
        let second = Project(name: "Drugi")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        let task = ProjectTask(title: "Važan zadatak", project: first)
        container.mainContext.insert(task)
        try container.mainContext.save()
        let data = try BackupService.export(context: container.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        let firstIndex = try XCTUnwrap(projects.firstIndex { ($0["id"] as? String) == first.id.uuidString })
        let secondIndex = try XCTUnwrap(projects.firstIndex { ($0["id"] as? String) == second.id.uuidString })
        projects[secondIndex]["tasks"] = projects[firstIndex]["tasks"]
        projects[firstIndex]["tasks"] = []
        json["projects"] = projects
        XCTAssertThrowsError(try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: container.mainContext))
        XCTAssertEqual(task.project?.id, first.id)
    }

    func testOrphanCannotBeSilentlyLostInExport() throws {
        let container = try memoryContainer()
        container.mainContext.insert(ProjectNote(text: "Nepovezana bilješka"))
        try container.mainContext.save()
        XCTAssertThrowsError(try BackupService.export(context: container.mainContext))
    }

    func testDiskStoreSurvivesContainerReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("office.store")
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let projectID: UUID
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let project = Project(name: "Trajni projekt")
            projectID = project.id
            container.mainContext.insert(project)
            let task = ProjectTask(title: "Trajni zadatak", project: project)
            container.mainContext.insert(task)
            let note = ProjectNote(text: "Početni zapis", project: project)
            container.mainContext.insert(note)
            try container.mainContext.save()
            // Exercise editing and a second durable save, not only insertion.
            project.name = "Uređeni trajni projekt"
            task.title = "Uređeni trajni zadatak"
            task.status = .completed
            note.text = "Ispravljeni zapis nakon razgovora"
            project.changePhase(to: .main)
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let project = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(project.id, projectID)
        XCTAssertEqual(project.name, "Uređeni trajni projekt")
        XCTAssertEqual(project.tasks.first?.title, "Uređeni trajni zadatak")
        XCTAssertEqual(project.tasks.first?.status, .completed)
        XCTAssertEqual(project.tasks.first?.project?.id, projectID)
        XCTAssertEqual(project.notes.first?.text, "Ispravljeni zapis nakon razgovora")
        XCTAssertEqual(project.phase, .main)
        XCTAssertEqual(project.phaseHistory.count, 2)
    }
}
