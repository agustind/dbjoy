import SwiftUI

/// Lists the connection's saved chats, filed in folders. Chats open on click and can be
/// renamed, moved (by menu or by dragging onto a folder) and deleted.
struct ChatBrowser: View {
    var model: AssistantModel
    var connectionID: UUID
    /// Called after a chat is opened.
    var didOpen: () -> Void

    private enum NameRequest: Identifiable {
        case renameChat(ChatSummary)
        case renameFolder(ChatFolder)
        /// Creates a folder, then moves the chat into it if one is given.
        case newFolder(moving: UUID?)

        var id: String {
            switch self {
            case .renameChat(let chat): "chat-\(chat.id)"
            case .renameFolder(let folder): "folder-\(folder.id)"
            case .newFolder(let chat): "new-\(chat?.uuidString ?? "")"
            }
        }
    }

    @State private var nameRequest: NameRequest?
    @State private var name = ""
    @State private var chatToDelete: ChatSummary?
    @State private var folderToDelete: ChatFolder?
    @State private var collapsed: Set<UUID> = []
    @State private var dropTarget: UUID?
    @State private var isTopLevelTargeted = false

    private var library: ChatLibrary { model.library }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { ask(.newFolder(moving: nil), name: "") } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.ghost)
                .font(.system(size: 12))
                .accessibilityIdentifier("chats-new-folder")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(isTopLevelTargeted ? Theme.accentFill : .clear)
            // Dropping a chat here takes it out of its folder.
            .dropDestination(for: String.self) { ids, _ in
                move(ids, to: nil)
            } isTargeted: { isTopLevelTargeted = $0 }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let topLevel = library.chats(for: connectionID, in: nil)
                    ForEach(topLevel) { chat in row(chat) }
                    ForEach(library.sortedFolders) { folder in
                        folderSection(folder)
                    }
                    if topLevel.isEmpty, library.folders.isEmpty {
                        Text("Chats are saved here automatically. Create folders to organize them.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } })) {
            TextField("Name", text: $name)
            Button(alertAction) { applyName() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(chatToDelete?.title ?? "")”?",
                            isPresented: Binding(get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }),
                            presenting: chatToDelete) { chat in
            Button("Delete Chat", role: .destructive) { delete(chat) }
        } message: { _ in
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete the folder “\(folderToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                            presenting: folderToDelete) { folder in
            Button("Delete Folder", role: .destructive) { library.deleteFolder(folder.id) }
        } message: { _ in
            Text("The chats in it are kept and move out of the folder.")
        }
    }

    // MARK: Rows

    private func folderSection(_ folder: ChatFolder) -> some View {
        let chats = library.chats(for: connectionID, in: folder.id)
        let isCollapsed = collapsed.contains(folder.id)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isCollapsed { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.accentText)
                    Text(folder.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(chats.count)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(dropTarget == folder.id ? Theme.accentFill : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-folder-\(folder.name)")
            .dropDestination(for: String.self) { ids, _ in
                collapsed.remove(folder.id)
                return move(ids, to: folder.id)
            } isTargeted: { dropTarget = $0 ? folder.id : (dropTarget == folder.id ? nil : dropTarget) }
            .contextMenu {
                Button("Rename…") { ask(.renameFolder(folder), name: folder.name) }
                Button("Delete Folder…", role: .destructive) { folderToDelete = folder }
            }

            if !isCollapsed {
                ForEach(chats) { chat in row(chat).padding(.leading, 16) }
                if chats.isEmpty {
                    Text("Drag chats here")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 34)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 6)
    }

    private func row(_ chat: ChatSummary) -> some View {
        let isCurrent = chat.id == model.chatID
        return Button {
            model.open(chat.id)
            didOpen()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? Theme.accentText : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(chat.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Theme.accentFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-\(chat.title)")
        .draggable(chat.id.uuidString)
        .contextMenu {
            Button("Rename…") { ask(.renameChat(chat), name: chat.title) }
            Menu("Move to") {
                Button("No Folder") { library.move(chat.id, to: nil) }
                    .disabled(chat.folderID == nil)
                if !library.folders.isEmpty { Divider() }
                ForEach(library.sortedFolders) { folder in
                    Button(folder.name) { library.move(chat.id, to: folder.id) }
                        .disabled(chat.folderID == folder.id)
                }
                Divider()
                Button("New Folder…") { ask(.newFolder(moving: chat.id), name: "") }
            }
            Divider()
            Button("Delete…", role: .destructive) { chatToDelete = chat }
        }
    }

    // MARK: Actions

    private var alertTitle: String {
        switch nameRequest {
        case .renameChat: "Rename Chat"
        case .renameFolder: "Rename Folder"
        case .newFolder, nil: "New Folder"
        }
    }

    private var alertAction: String {
        if case .newFolder = nameRequest { return "Create" }
        return "Rename"
    }

    private func ask(_ request: NameRequest, name: String) {
        self.name = name
        nameRequest = request
    }

    private func applyName() {
        switch nameRequest {
        case .renameChat(let chat): library.rename(chat.id, to: name)
        case .renameFolder(let folder): library.renameFolder(folder.id, to: name)
        case .newFolder(let chatID):
            if let folder = library.createFolder(named: name), let chatID { library.move(chatID, to: folder.id) }
        case nil: break
        }
        nameRequest = nil
    }

    @discardableResult
    private func move(_ ids: [String], to folderID: UUID?) -> Bool {
        let chats = ids.compactMap(UUID.init(uuidString:)).filter { library.summary($0) != nil }
        for id in chats { library.move(id, to: folderID) }
        return !chats.isEmpty
    }

    private func delete(_ chat: ChatSummary) {
        if chat.id == model.chatID { model.reset() }
        library.delete(chat.id)
    }
}
