import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// A cask's font files and its license in a zip file, for Install on Mac to hand the share sheet. AirDropped to a
/// Mac, it opens to a folder whose fonts Font Book installs. One file rather than one per face: a Nerd Font family
/// would otherwise drop nearly a hundred files into Downloads. The fonts are this build's copies, from the cask's
/// On-Demand Resources tag, and the license goes with them, as the OFL asks of every copy.
///
/// Made only when a destination is picked, so the share sheet opens at once and the tag downloads only if the
/// fonts are really sent.
nonisolated struct FontArchive: Transferable {
    let token: String
    let name: String
    let tag: String
    let assets: [String]

    @MainActor init(_ cask: Cask, tag: String) {
        token = cask.token
        name = cask.name
        self.tag = tag
        assets = cask.assets
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { archive in
            SentTransferredFile(try await archive.write())
        }
        .suggestedFileName { "\($0.folderName).zip" }
    }

    enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let asset): String(localized: "This build's copy of \(asset) couldn't be read.")
            }
        }
    }

    /// The family's name as a folder can carry it.
    var folderName: String {
        name.replacing(/[\/:]/, with: "-")
    }

    private func write() async throws -> URL {
        let files = FileManager.default
        // One export at a time is all the share sheet needs; anything older has been sent or abandoned.
        let exports = files.temporaryDirectory.appending(path: "Install on Mac", directoryHint: .isDirectory)
        try? files.removeItem(at: exports)
        let folder = exports.appending(path: folderName, directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        let request = NSBundleResourceRequest(tags: [tag])
        try await request.beginAccessingResources()
        defer { request.endAccessingResources() }
        for asset in assets {
            guard let data = NSDataAsset(name: asset)?.data else { throw Failure.unreadable(asset) }
            try data.write(to: folder.appending(path: "\(asset).\(Self.fileExtension(of: data))"))
        }
        if let license = await Licenses.text(for: token) {
            try license.write(to: folder.appending(path: "LICENSE.txt"), atomically: true, encoding: .utf8)
        }
        return try Self.zip(folder, to: exports.appending(path: "\(folderName).zip"))
    }

    /// What the file is, from its first four bytes: the assets are named after a face, not a file, so they carry
    /// no extension of their own, and a Mac goes by the extension.
    static func fileExtension(of data: Data) -> String {
        switch Data(data.prefix(4)) {
        case Data("OTTO".utf8): "otf"
        case Data("ttcf".utf8): "ttc"
        default: "ttf"
        }
    }

    /// Zips the folder, as the Files app does: a coordinated read for uploading hands back a zip of a directory,
    /// which lasts only while the block runs.
    private static func zip(_ folder: URL, to destination: URL) throws -> URL {
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
