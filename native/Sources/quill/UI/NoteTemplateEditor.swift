import SwiftUI
import UniformTypeIdentifiers

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
                }.padding(.horizontal).padding(.top, 12)
                HStack {
                    Button("Import…", action: importTemplate).disabled(drafts.count >= 100)
                    Button("Export…", action: exportTemplate).disabled(index == nil)
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
            .foregroundStyle(.primary).background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: drafts) { _, _ in message = "Unsaved changes" }
    }
    private func importTemplate() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Import as a new draft. Existing templates stay unchanged until you save."
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            do {
                guard drafts.count < 100 else { throw TranscriptionFailure("Keep at most 100 templates.") }
                let imported = try TemplateExchange.read(file)
                drafts.append(imported); selected = imported.id; message = "Imported draft. Review it, then save."
            } catch { message = "Could not import this template. Check its format and size." }
        }
    }
    private func exportTemplate() {
        guard let index else { return }
        let template = drafts[index]
        do { _ = try TemplateExchange.encode(template) }
        catch { message = "Give this template a name and valid sections before exporting."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ClawMinutes-template.json"
        panel.message = "Export this template to a new file. This includes its context and section instructions."
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            do { try TemplateExchange.write(template, to: file); message = "Template exported." }
            catch { message = "Could not export. Choose a new file in a writable folder." }
        }
    }

}
