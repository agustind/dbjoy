import DBCore
import SwiftUI

struct DiagramView: View {
    @Bindable var model: DiagramModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "ER diagram", subtitle: "\(model.schema) · \(model.nodes.count) tables · \(model.edges.count) relationships",
                       showsToolbar: false) {
                EmptyView()
            } trailing: {
                Toggle("Include views", isOn: $model.includeViews)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: model.includeViews) { _, _ in Task { await model.load() } }
                HStack(spacing: 0) {
                    Button { model.zoom = max(0.3, model.zoom - 0.1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.ghost)
                    Text("\(Int(model.zoom * 100))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 48)
                    Button { model.zoom = min(2, model.zoom + 0.1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.ghost)
                }
                .padding(.horizontal, 2)
                .frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
                Button { Task { await model.load() } } label: { Label("Re-layout", systemImage: "arrow.clockwise") }
                    .buttonStyle(.outline)
            } toolbar: {
                EmptyView()
            }
            Rectangle().fill(Theme.separator).frame(height: 1)

            if let error = model.error {
                ErrorBanner(message: error)
            }
            ScrollView([.horizontal, .vertical]) {
                let size = model.canvasSize
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedNode = nil }
                    Canvas { context, _ in drawEdges(in: context) }
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    ForEach(model.nodes) { node in
                        DiagramTableBox(node: node, isSelected: model.selectedNode == node.name,
                                        isRelated: isRelated(node.name))
                            .offset(x: node.position.x, y: node.position.y)
                            .gesture(drag(node.name))
                            .onTapGesture(count: 2) {
                                model.workspace?.open(ObjectRef(schema: model.schema, name: node.name, kind: node.kind))
                            }
                            .onTapGesture { model.selectedNode = node.name }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(model.zoom, anchor: .topLeading)
                .frame(width: size.width * model.zoom, height: size.height * model.zoom, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .background(Theme.sidebarBackground.opacity(0.35))
            .overlay {
                if model.isLoading { ProgressView() }
                else if model.nodes.isEmpty, model.error == nil { Text("No tables in \(model.schema)").foregroundStyle(.secondary) }
            }
        }
        .task { if model.nodes.isEmpty { await model.load() } }
    }

    private func isRelated(_ name: String) -> Bool {
        guard let selected = model.selectedNode else { return false }
        return model.edges.contains {
            ($0.table.name == selected && $0.referencedTable.name == name) || ($0.referencedTable.name == selected && $0.table.name == name)
        }
    }

    @State private var lastTranslation: CGSize = .zero

    private func drag(_ name: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastTranslation.width,
                                   height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                model.move(name, by: delta)
            }
            .onEnded { _ in lastTranslation = .zero }
    }

    private func drawEdges(in context: GraphicsContext) {
        for fk in model.edges {
            guard let source = model.node(named: fk.table.name), let target = model.node(named: fk.referencedTable.name) else { continue }
            let highlighted = model.selectedNode == source.name || model.selectedNode == target.name
            let color: Color = highlighted ? Theme.accent : Theme.textTertiary
            let sourceY = source.anchorY(for: fk.columns.first ?? "")
            let targetY = target.anchorY(for: fk.referencedColumns.first ?? "")

            var path = Path()
            let start: CGPoint
            let end: CGPoint
            if source.name == target.name {
                // Self reference: loop on the right side.
                start = CGPoint(x: source.frame.maxX, y: sourceY)
                end = CGPoint(x: source.frame.maxX, y: targetY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + 50, y: start.y), control2: CGPoint(x: end.x + 50, y: end.y))
            } else {
                let targetIsRight = target.frame.midX > source.frame.midX
                start = CGPoint(x: targetIsRight ? source.frame.maxX : source.frame.minX, y: sourceY)
                end = CGPoint(x: targetIsRight ? target.frame.minX : target.frame.maxX, y: targetY)
                let bend = max(40, abs(end.x - start.x) / 2)
                path.move(to: start)
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + (targetIsRight ? bend : -bend), y: start.y),
                              control2: CGPoint(x: end.x + (targetIsRight ? -bend : bend), y: end.y))
                // Crow's foot on the "many" (referencing) side.
                let dir: CGFloat = targetIsRight ? 1 : -1
                var foot = Path()
                foot.move(to: CGPoint(x: start.x + dir * 10, y: start.y))
                foot.addLine(to: CGPoint(x: start.x, y: start.y - 5))
                foot.move(to: CGPoint(x: start.x + dir * 10, y: start.y))
                foot.addLine(to: CGPoint(x: start.x, y: start.y + 5))
                context.stroke(foot, with: .color(color), lineWidth: 1.5)
                // Bar on the "one" (referenced) side.
                var bar = Path()
                bar.move(to: CGPoint(x: end.x - dir * 6, y: end.y - 5))
                bar.addLine(to: CGPoint(x: end.x - dir * 6, y: end.y + 5))
                context.stroke(bar, with: .color(color), lineWidth: 1.5)
            }
            context.stroke(path, with: .color(color), lineWidth: highlighted ? 2 : 1.2)
        }
    }
}

private struct DiagramTableBox: View {
    var node: DiagramNode
    var isSelected: Bool
    var isRelated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: node.kind.systemImage).font(.caption)
                Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(node.kind == .table ? Theme.accentText : Theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(width: DiagramNode.width, height: DiagramNode.headerHeight, alignment: .leading)
            .background(node.kind == .table ? Theme.accentFill : Theme.elevated)

            ForEach(node.columns) { column in
                HStack(spacing: 4) {
                    Group {
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                        } else if node.foreignKeyColumns.contains(column.name) {
                            Image(systemName: "link").foregroundStyle(.blue)
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 9))
                    .frame(width: 12)
                    Text(column.name).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(column.dataType).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: DiagramNode.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(width: node.size.width, height: node.size.height, alignment: .top)
        .background(Theme.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Theme.accent : (isRelated ? Theme.accentStroke : Theme.border),
                        lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
