import SwiftUI

@MainActor struct NoteTemplateEditor: View {
    @ObservedObject var controller: MenuBarController
    @State private var drafts: [NoteTemplate] = MeetingNotesSettings.templates
    @State private var selected = MeetingNotesSettings.selected.id
    @State private var message = ""
    private var index: Int? { drafts.firstIndex { $0.id == selected } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                Button("New template", systemImage: "plus") {
                    let item = NoteTemplate(id: UUID().uuidString, name: "New template", context: "", sections: [.init(title: "Summary", instructions: "Main points and outcomes.")])
                    drafts.append(item); selected = item.id; message = "Unsaved changes"
                }.padding(.horizontal)
                List(selection: $selected) { ForEach(drafts) { item in Text(item.name).tag(item.id) } }
                HStack {
                    Button("Duplicate") { if let i = index { var copy = drafts[i]; copy.id = UUID().uuidString; copy.name += " copy"; drafts.append(copy); selected = copy.id; message = "Unsaved changes" } }
                    Button("Delete") { if let i = index, drafts.count > 1 { drafts.remove(at: i); selected = drafts[0].id; message = "Unsaved changes" } }.disabled(drafts.count <= 1)
                }.padding()
            }.frame(width: 210)
            Divider()
            if let i = index {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Template name", text: $drafts[i].name).font(.title2).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Meeting context").font(.headline)
                            TextEditor(text: $drafts[i].context).frame(minHeight: 100).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                            Text("Sections").font(.headline)
                            ForEach(drafts[i].sections.indices, id: \.self) { section in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        TextField("Section heading", text: $drafts[i].sections[section].title).fontWeight(.semibold)
                                        Button { drafts[i].sections.swapAt(section, section-1) } label: { Image(systemName: "arrow.up") }.disabled(section == 0).help("Move section up")
                                        Button { drafts[i].sections.swapAt(section, section+1) } label: { Image(systemName: "arrow.down") }.disabled(section == drafts[i].sections.count-1).help("Move section down")
                                        Button { drafts[i].sections.remove(at: section) } label: { Image(systemName: "minus.circle") }.disabled(drafts[i].sections.count <= 1).help("Remove section")
                                    }
                                    TextEditor(text: $drafts[i].sections[section].instructions).frame(minHeight: 55)
                                }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                            Button("Add section", systemImage: "plus") { drafts[i].sections.append(.init(title: "New section", instructions: "")) }.disabled(drafts[i].sections.count >= 30)
                        }
                    }
                    Text("Templates guide AI notes. Generated actions and people evidence are review candidates. No tasks or people files are changed.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save and use template") { if controller.saveTemplates(drafts, selected: selected) { message = "Saved. This template will be used for the next recording." } }.buttonStyle(.borderedProminent)
                    }
                }.padding(20)
            }
        }.frame(minWidth: 740, minHeight: 600)
            .onChange(of: drafts) { _, _ in message = "Unsaved changes" }
    }
}
