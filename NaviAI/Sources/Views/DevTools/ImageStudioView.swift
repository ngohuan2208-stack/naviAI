import SwiftUI

struct ImageStudioView: View {
    private struct ResultItem: Identifiable {
        let id = UUID()
        let prompt: String
        let data: Data
    }

    @State private var prompt = ""
    @State private var generating = false
    @State private var results: [ResultItem] = []
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Prompt") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 70)
                Button {
                    generate()
                } label: {
                    if generating {
                        HStack { ProgressView(); Text("Generating…") }
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || generating)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if let ui = UIImage(data: item.data) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text(item.prompt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Image Studio")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .imageStudioGenerateRequested)) { note in
            if let text = note.object as? String {
                prompt = text
                generate()
            }
        }
    }

    private func generate() {
        let p = prompt
        guard !p.isEmpty else { return }
        generating = true
        errorText = nil
        Task {
            do {
                let image = try await ImagePipeline.shared.generate(prompt: p)
                results.insert(ResultItem(prompt: p, data: image.data), at: 0)
            } catch {
                errorText = error.localizedDescription
            }
            generating = false
        }
    }
}
