import Foundation
import SwiftUI

/// Opens Install on Mac's sheet.
struct InstallOnMacButton: View {
    let cask: Cask
    var isNerdVersion = false
    @State private var isPresented = false

    var body: some View {
        Button("Install on Mac", systemImage: "laptopcomputer.and.arrow.down") { isPresented = true }
            .buttonStyle(.glass)
            .accessibilityLabel(isNerdVersion ? "Install Nerd Font on Mac" : "Install on Mac")
            .accessibilityHint("Downloads \(cask.bytes.formatted(.byteCount(style: .file))) to send to a Mac.")
            .accessibilityIdentifier("installOnMac")
            .sheet(isPresented: $isPresented) {
                InstallOnMacSheet(cask: cask)
            }
    }
}

/// Install on Mac's sheet: says what will happen, downloads the cask's fonts with the same progress bar as Install
/// and Try It Out, then hands the share sheet a zip of them and their license, for AirDrop to a Mac, where Font Book
/// installs them. iOS can't install fonts on a Mac itself. One zip rather than one file per face: a Nerd Font family
/// would otherwise drop nearly a hundred files into Downloads. The license goes with the fonts, as the OFL asks of
/// every copy.
struct InstallOnMacSheet: View {
    let cask: Cask
    @Environment(\.dismiss) private var dismiss
    @State private var archive = MacArchive()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Typecask can't install fonts on your Mac, but it can send them there.")
                        .foregroundStyle(.secondary)
                    step(1, "Download them here", """
                         Typecask downloads \(cask.name)'s fonts, \(size), and puts them in a zip file with their \
                         license.
                         """)
                    step(2, "Send them to your Mac",
                         "Choose your Mac under AirDrop. The zip file arrives in its Downloads folder.")
                    step(3, "Install them on your Mac", """
                         Open the zip file, then double-click each font file and click Install. Or drag them all \
                         into Font Book.
                         """)
                    action
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Install on Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("installOnMacDone")
                }
            }
        }
    }

    private var size: String {
        cask.bytes.formatted(.byteCount(style: .file))
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var action: some View {
        switch archive.phase {
        case .idle:
            Button {
                Task { await archive.prepare(cask) }
            } label: {
                Label("Download \(size)", systemImage: "arrow.down.circle")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("downloadForMac")
        case .downloading:
            ProgressView("Downloading \(size)…", value: archive.progress)
                .frame(maxWidth: 280)
        case .zipping:
            ProgressView("Making the zip file…")
        case .ready(let zip):
            ShareLink(item: zip, preview: SharePreview(cask.name)) {
                Label("Send to Your Mac", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("sendToMac")
        case .failed(let message):
            // Red on the icon alone, as the font page shows a failed install.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Downloads a cask's On-Demand Resources tag and writes its fonts and license into a zip file.
@Observable
final class MacArchive {
    enum Phase {
        case idle
        case downloading
        case zipping
        case ready(URL)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var progress = 0.0

    func prepare(_ cask: Cask) async {
        phase = .downloading
        let request = NSBundleResourceRequest(tags: [cask.pack ?? cask.token])
        let observation = request.progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.progress = fraction }
        }
        defer { observation.invalidate() }
        do {
            try await request.beginAccessingResources()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        defer { request.endAccessingResources() }
        phase = .zipping
        let license = await Licenses.text(for: cask.token)
        do {
            phase = .ready(try await Self.write(name: cask.name, assets: cask.assets, license: license))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let asset): String(localized: "This build's copy of \(asset) couldn't be read.")
            }
        }
    }

    /// Off the main actor: a CJK family is over 100 MB to copy and zip. Called while the tag is being accessed.
    @concurrent
    nonisolated private static func write(name: String, assets: [String], license: String?) async throws -> URL {
        let files = FileManager.default
        let folderName = name.replacing(/[\/:]/, with: "-")
        // One export at a time is all the share sheet needs; anything older has been sent or abandoned.
        let exports = files.temporaryDirectory.appending(path: "Install on Mac", directoryHint: .isDirectory)
        try? files.removeItem(at: exports)
        let folder = exports.appending(path: folderName, directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for asset in assets {
            guard let data = NSDataAsset(name: asset)?.data else { throw Failure.unreadable(asset) }
            try data.write(to: folder.appending(path: "\(asset).\(fileExtension(of: data))"))
        }
        if let license {
            try license.write(to: folder.appending(path: "LICENSE.txt"), atomically: true, encoding: .utf8)
        }
        return try zip(folder, to: exports.appending(path: "\(folderName).zip"))
    }

    /// What the file is, from its first four bytes: the assets are named after a face, not a file, so they carry
    /// no extension of their own, and a Mac goes by the extension.
    nonisolated static func fileExtension(of data: Data) -> String {
        switch Data(data.prefix(4)) {
        case Data("OTTO".utf8): "otf"
        case Data("ttcf".utf8): "ttc"
        default: "ttf"
        }
    }

    /// Zips the folder, as the Files app does: a coordinated read for uploading hands back a zip of a directory,
    /// which lasts only while the block runs.
    nonisolated private static func zip(_ folder: URL, to destination: URL) throws -> URL {
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            do {
                try FileManager.default.moveItem(at: zip, to: destination)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError {
            throw error
        }
        return destination
    }
}
