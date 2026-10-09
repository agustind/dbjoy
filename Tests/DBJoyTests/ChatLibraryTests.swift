@testable import DBJoy
import DBCore
import Foundation
import Testing

/// A fresh folder for files a test writes, never the app's own data folder.
func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dbjoy-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
struct ChatLibraryTests {
    let connection = UUID()

    private func content(_ text: String) -> StoredChat {
        var conversation = LLMConversation(provider: .anthropic, model: "claude-opus-5-5")
        conversation.addUser(text)
        return StoredChat(conversation: conversation, items: [StoredChatItem(kind: .user, text: text)])
    }

    @Test func savesAndReloadsChats() {
        let directory = temporaryDirectory()
        let library = ChatLibrary(directory: directory)
        let id = UUID()
        library.save(id, title: "Revenue by category", connectionID: connection, content: content("Revenue?"))
        // Saving again keeps the user's title.
        library.rename(id, to: "Q3 revenue")
        library.save(id, title: "Revenue by category", connectionID: connection, content: content("Revenue?"))

        let reloaded = ChatLibrary(directory: directory)
        #expect(reloaded.chats(for: connection, in: nil).map(\.title) == ["Q3 revenue"])
        #expect(reloaded.chats(for: UUID(), in: nil).isEmpty)
        let stored = reloaded.load(id)
        #expect(stored?.items.first?.text == "Revenue?")
        #expect(stored?.conversation?.messages.count == 1)
        #expect(stored?.conversation?.provider == .anthropic)
    }

    @Test func foldersOrganizeChats() throws {
        let library = ChatLibrary(directory: temporaryDirectory())
        let a = UUID(), b = UUID()
        library.save(a, title: "A", connectionID: connection, content: content("a"))
        library.save(b, title: "B", connectionID: connection, content: content("b"))
        let folder = try #require(library.createFolder(named: "  Reports "))
        #expect(folder.name == "Reports")
        #expect(library.createFolder(named: "   ") == nil)

        library.move(a, to: folder.id)
        #expect(library.chats(for: connection, in: folder.id).map(\.id) == [a])
        #expect(library.chats(for: connection, in: nil).map(\.id) == [b])

        library.renameFolder(folder.id, to: "Monthly")
        #expect(library.folders.map(\.name) == ["Monthly"])

        // Deleting a folder keeps its chats.
        library.deleteFolder(folder.id)
        #expect(library.folders.isEmpty)
        #expect(Set(library.chats(for: connection, in: nil).map(\.id)) == [a, b])
    }

    @Test func deletingRemovesFiles() {
        let directory = temporaryDirectory()
        let library = ChatLibrary(directory: directory)
        let a = UUID(), b = UUID(), other = UUID()
        library.save(a, title: "A", connectionID: connection, content: content("a"))
        library.save(b, title: "B", connectionID: connection, content: content("b"))
        library.save(other, title: "Other", connectionID: UUID(), content: content("o"))

        library.delete(a)
        #expect(library.load(a) == nil)
        library.deleteChats(for: connection)
        #expect(library.load(b) == nil)
        #expect(library.chats.map(\.id) == [other])
        #expect(library.load(other) != nil)
    }

    @Test func stepsKeepTheirFirstRows() {
        let step = AssistantStep(title: "Ran a query", sql: "SELECT n FROM t")
        step.result = QueryResult(columns: [ResultColumn(name: "n", typeName: "int4", category: .number)],
                                  rows: (1...120).map { [String($0)] }, commandTag: "SELECT 120")
        step.state = .done
        let restored = StoredStep(step).assistantStep
        #expect(restored.state == .done)
        #expect(restored.sql == "SELECT n FROM t")
        #expect(restored.result?.rows.count == StoredStep.maxRows)
        #expect(restored.result?.columns.map(\.name) == ["n"])
        #expect(restored.totalRows == 120)

        let pending = AssistantStep(title: "Delete old rows", sql: "DELETE FROM t")
        pending.state = .awaitingApproval
        #expect(StoredStep(pending).assistantStep.state == .skipped)
    }
}
