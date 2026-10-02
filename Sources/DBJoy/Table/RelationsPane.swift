import DBCore
import SwiftUI

/// Visual map of a table's foreign keys and dependent objects.
struct RelationsPane: View {
    var model: TableTabModel

    var body: some View {
        if let relations = model.relations {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    RelationshipMap(center: model.ref, relations: relations) { ref in model.workspace?.open(ref) }
                        .frame(maxWidth: .infinity)

                    if relations.outgoing.isEmpty && relations.incoming.isEmpty {
                        Text("No foreign keys reference or are declared on \(model.ref.name).")
                            .foregroundStyle(.secondary)
                    }
                    foreignKeySection("References", subtitle: "Foreign keys declared on this table", keys: relations.outgoing,
                                      target: \.referencedTable)
                    foreignKeySection("Referenced by", subtitle: "Foreign keys on other tables pointing here", keys: relations.incoming,
                                      target: \.table)
                    dependencySection("Dependent objects", items: relations.dependents)
                    dependencySection("Depends on", items: relations.dependencies)
                }
                .padding(20)
            }
            .background(Theme.contentBackground)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func foreignKeySection(_ title: String, subtitle: String, keys: [ForeignKeyInfo],
                                   target: KeyPath<ForeignKeyInfo, ObjectRef>) -> some View {
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                ForEach(keys) { fk in
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(.blue)
                        Text("\(fk.table.name)(\(fk.columns.joined(separator: ", ")))").font(.callout.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Button("\(fk.referencedTable.description)(\(fk.referencedColumns.joined(separator: ", ")))") {
                            model.workspace?.open(fk[keyPath: target])
                        }
                        .buttonStyle(.link)
                        .font(.callout.monospaced())
                        Spacer()
                        Text("ON UPDATE \(fk.onUpdate) · ON DELETE \(fk.onDelete)")
                            .font(.caption).foregroundStyle(fk.onDelete == "CASCADE" ? .orange : .secondary)
                    }
                    .help(fk.name)
                }
            }
        }
    }

    @ViewBuilder
    private func dependencySection(_ title: String, items: [DependencyInfo]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(items) { item in
                    Button {
                        model.workspace?.open(item.object)
                    } label: {
                        Label("\(item.object.description)  ·  \(item.object.kind.displayName)", systemImage: item.object.kind.systemImage)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

private struct BoxAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Incoming tables → this table → referenced tables, connected by lines.
private struct RelationshipMap: View {
    var center: ObjectRef
    var relations: TableRelations
    var open: (ObjectRef) -> Void

    private var incoming: [ObjectRef] { unique(relations.incoming.map(\.table).filter { $0 != center }) }
    private var outgoing: [ObjectRef] { unique(relations.outgoing.map(\.referencedTable).filter { $0 != center }) }

    var body: some View {
        HStack(alignment: .center, spacing: 90) {
            column(incoming, side: "in")
            box(center, id: "center", highlighted: true)
            column(outgoing, side: "out")
        }
        .padding(.vertical, 8)
        .backgroundPreferenceValue(BoxAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let centerAnchor = anchors["center"] {
                    let centerRect = proxy[centerAnchor]
                    Path { path in
                        for ref in incoming {
                            guard let anchor = anchors["in:\(ref)"] else { continue }
                            connect(&path, from: CGPoint(x: proxy[anchor].maxX, y: proxy[anchor].midY),
                                    to: CGPoint(x: centerRect.minX, y: centerRect.midY))
                        }
                        for ref in outgoing {
                            guard let anchor = anchors["out:\(ref)"] else { continue }
                            connect(&path, from: CGPoint(x: centerRect.maxX, y: centerRect.midY),
                                    to: CGPoint(x: proxy[anchor].minX, y: proxy[anchor].midY))
                        }
                    }
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)
                }
            }
        }
    }

    private func connect(_ path: inout Path, from: CGPoint, to: CGPoint) {
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: from.x + 45, y: from.y), control2: CGPoint(x: to.x - 45, y: to.y))
        // Arrow head pointing at the referenced side.
        path.move(to: CGPoint(x: to.x - 7, y: to.y - 4))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: to.x - 7, y: to.y + 4))
    }

    private func column(_ refs: [ObjectRef], side: String) -> some View {
        VStack(alignment: side == "in" ? .trailing : .leading, spacing: 10) {
            if refs.isEmpty {
                Text(side == "in" ? "Nothing references this table" : "No references")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 180)
            }
            ForEach(refs, id: \.self) { ref in box(ref, id: "\(side):\(ref)", highlighted: false) }
        }
    }

    private func box(_ ref: ObjectRef, id: String, highlighted: Bool) -> some View {
        Button { if !highlighted { open(ref) } } label: {
            Label(ref.schema == center.schema ? ref.name : ref.description, systemImage: ref.kind.systemImage)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 140)
                .background(highlighted ? Theme.accentFill : Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlighted ? Theme.accentStroke : Theme.border))
        }
        .buttonStyle(.plain)
        .anchorPreference(key: BoxAnchorKey.self, value: .bounds) { [id: $0] }
    }

    private func unique(_ refs: [ObjectRef]) -> [ObjectRef] {
        var seen = Set<ObjectRef>()
        return refs.filter { seen.insert($0).inserted }
    }
}
