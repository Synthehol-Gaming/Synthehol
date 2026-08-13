import SwiftUI
import SyntheholKit

struct CreateBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var windowsVersion: WindowsVersion = .win10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle")
                .font(.title2.bold())

            if model.runtime == nil {
                RuntimeInstallPrompt()
            }

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Steam"))
                Picker("Windows Version", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let bottleName = name.trimmingCharacters(in: .whitespaces)
                    let version = windowsVersion
                    dismiss()
                    Task { await model.createBottle(name: bottleName, windowsVersion: version) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.runtime == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Shown when no Wine runtime is installed yet: explains and offers install.
struct RuntimeInstallPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Wine runtime required", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Synthehol needs to download the Wine runtime (~330 MB) before it can create bottles.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let progress = model.runtimeProgress {
                RuntimeProgressView(progress: progress)
            } else {
                Button("Download Runtime") {
                    Task { await model.installRuntime() }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RuntimeProgressView: View {
    let progress: RuntimeInstallProgress

    var body: some View {
        switch progress {
        case .downloading(let done, let total):
            if let total {
                ProgressView(
                    "Downloading… \(done / 1_048_576) MB of \(total / 1_048_576) MB",
                    value: Double(done), total: Double(total)
                )
            } else {
                ProgressView("Downloading… \(done / 1_048_576) MB")
            }
        case .verifying:
            ProgressView("Verifying checksum…")
        case .extracting:
            ProgressView("Extracting…")
        case .finishing:
            ProgressView("Finishing…")
        }
    }
}
