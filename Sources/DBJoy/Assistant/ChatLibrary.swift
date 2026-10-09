import DBCore
import Foundation
import Observation

struct ChatFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// A saved chat as listed in the chat browser. Its transcript lives in its own file.
struct ChatSummary: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var connectionID: UUID
    var folderID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
}

/// A chat's transcript: what the panel shows, and the model-side history to continue it.
struct StoredChat: Codable {
    var conversation: LLMConversation?
    var items: [StoredChatItem]
}

struct StoredChatItem: Codable {
    enum Kind: String, Codable { case user, reply, step, problem }

    var kind: Kind
    var text: String?
    var step: StoredStep?
}

/// A tool step with the first rows of its result, enough to redraw the chat.
struct StoredStep: Codable {
    static let maxRows = 50

    var title: String
    var sql: String?
    var error: String?
    var state: String
    var columns: [String]?
    var columnTypes: [String]?
    var rows: [[String?]]?
    var rowCount: Int?
    var truncated: Bool?
    var commandTag: String?
    var rowsAffected: Int?
}

/// Saved assistant chats and the folders they're filed in. Chats belong to a connection;
/// folders are shared by every connection.
@MainActor @Observable
final class ChatLibrary {
    static let shared = ChatLibrary(directory: AppFiles.directory)

    private(set) var folders: [ChatFolder] = []
    private(set) var chats: [ChatSummary] = []
    @ObservationIgnored private let directory: URL

    private struct Index: Codable {
        var folders: [ChatFolder]
        var chats: [ChatSummary]
    }

    init(directory: URL) {
        self.directory = directory
        let index = AppFiles.load(Index.self, at: indexURL)
        folders = index?.folders ?? []
        chats = index?.chats ?? []
    }

    private var indexURL: URL { directory.appendingPathComponent("chats.json") }
    private func chatURL(_ id: UUID) -> URL { directory.appendingPathComponent("chat-\(id.uuidString).json") }

    private func persistIndex() {
        AppFiles.save(Index(folders: folders, chats: chats), at: indexURL)
    }

    // MARK: Chats

    /// This connection's chats, most recently used first.
    func chats(for connectionID: UUID, in folderID: UUID?) -> [ChatSummary] {
        chats.filter { $0.connectionID == connectionID && $0.folderID == folderID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func summary(_ id: UUID) -> ChatSummary? {
        chats.first { $0.id == id }
    }

    /// Creates or updates a chat. Keeps the folder and title the user chose.
    func save(_ id: UUID, title: String, connectionID: UUID, content: StoredChat) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            chats[index].updatedAt = Date()
        } else {
            chats.append(ChatSummary(id: id, title: title, connectionID: connectionID))
        }
        AppFiles.save(content, at: chatURL(id))
        persistIndex()
    }

    func load(_ id: UUID) -> StoredChat? {
        AppFiles.load(StoredChat.self, at: chatURL(id))
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = title
        persistIndex()
    }

    func move(_ id: UUID, to folderID: UUID?) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].folderID = folderID
        persistIndex()
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: chatURL(id))
        persistIndex()
    }

    /// Removes every chat of a deleted connection.
    func deleteChats(for connectionID: UUID) {
        for chat in chats where chat.connectionID == connectionID {
            try? FileManager.default.removeItem(at: chatURL(chat.id))
        }
        chats.removeAll { $0.connectionID == connectionID }
        persistIndex()
    }

    // MARK: Folders

    var sortedFolders: [ChatFolder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createFolder(named name: String) -> ChatFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folder = ChatFolder(name: name)
        folders.append(folder)
        persistIndex()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        persistIndex()
    }

    /// Deletes the folder; its chats move back to the top level.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in chats.indices where chats[index].folderID == id { chats[index].folderID = nil }
        persistIndex()
    }
}

// MARK: - Converting chat items

extension StoredChatItem {
    @MainActor init(_ item: ChatItem) {
        switch item.kind {
        case .user(let text): self.init(kind: .user, text: text)
        case .reply(let text): self.init(kind: .reply, text: text)
        case .problem(let text): self.init(kind: .problem, text: text)
        case .step(let step): self.init(kind: .step, step: StoredStep(step))
        }
    }

    @MainActor var chatItem: ChatItem? {
        switch kind {
        case .user: text.map { ChatItem(kind: .user($0)) }
        case .reply: text.map { ChatItem(kind: .reply($0)) }
        case .problem: text.map { ChatItem(kind: .problem($0)) }
        case .step: step.map { ChatItem(kind: .step($0.assistantStep)) }
        }
    }
}

extension StoredStep {
    @MainActor init(_ step: AssistantStep) {
        title = step.title
        sql = step.sql
        error = step.error
        // A change still waiting for approval can't be approved after reopening.
        state = switch step.state {
        case .done: "done"
        case .failed: "failed"
        case .running, .awaitingApproval, .skipped: "skipped"
        }
        if let result = step.result {
            columns = result.columns.map(\.name)
            columnTypes = result.columns.map(\.typeName)
            rows = Array(result.rows.prefix(Self.maxRows))
            rowCount = result.rows.count
            truncated = result.truncated
            commandTag = result.commandTag
            rowsAffected = result.rowsAffected
        }
    }

    @MainActor var assistantStep: AssistantStep {
        let step = AssistantStep(title: title, sql: sql)
        step.error = error
        step.state = switch state {
        case "done": .done
        case "failed": .failed
        default: .skipped
        }
        if let commandTag {
            let types = columnTypes ?? []
            let resultColumns = (columns ?? []).enumerated().map { index, name in
                ResultColumn(name: name, typeName: types.indices.contains(index) ? types[index] : "", category: .other)
            }
            step.result = QueryResult(columns: resultColumns, rows: rows ?? [], commandTag: commandTag,
                                      rowsAffected: rowsAffected, truncated: truncated ?? false)
            step.totalRows = rowCount
        }
        return step
    }
}
