//
//  DeckImportModifier.swift
//  AppShared
//
//  Created by Vladimir Gusev on 13.06.2026.
//

public import SwiftUI
import Theme
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit

/// Presents UIKit's document picker directly. SwiftUI's `fileImporter` did
/// nothing on tap in some sideloaded builds; this also asks iOS for a local
/// copy (`asCopy`), so no security-scoped access or iCloud download is needed.
@MainActor
final class PackagePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = PackagePicker()
    private var onPick: ((Result<URL, any Error>) -> Void)?

    func present(onPick: @escaping (Result<URL, any Error>) -> Void) {
        self.onPick = onPick
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        guard let top = Self.topViewController() else {
            onPick(.failure(CocoaError(.userCancelled)))
            return
        }
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        onPick?(.success(url))
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }
}
#endif

private struct DeckImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var externalFile: URL?
    let onRefresh: () -> Void

    @State private var status: ImportStatusBanner.Status?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            #if canImport(UIKit)
            .onChange(of: isPresented) { _, show in
                guard show else { return }
                isPresented = false
                PackagePicker.shared.present { result in handleImport(result) }
            }
            #else
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data]) { result in
                handleImport(result)
            }
            #endif
            .onChange(of: externalFile) { _, url in
                guard let url else { return }
                externalFile = nil
                handleImport(.success(url))
            }
            .overlay(alignment: .top) { ImportStatusBanner(status: status) }
            .animation(AmgiMotion.momentum, value: status)
            .alert(
                "Couldn't import deck",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

}

private extension DeckImportModifier {
    func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let ext = url.pathExtension.lowercased()
            guard ext == "apkg" || ext == "colpkg" else {
                failure = "Unsupported file type. Please select an .apkg or .colpkg file."
                return
            }
            Task {
                status = .importing(fileName: url.lastPathComponent)
                do {
                    let summary = try await ImportHelper.importPackage(from: url)
                    onRefresh()
                    status = .finished(summary: summary)
                    try? await Task.sleep(for: .seconds(3))
                    status = nil
                } catch {
                    status = nil
                    failure = error.localizedDescription
                }
            }
        case .failure(let error):
            failure = "Could not select file: \(error.localizedDescription)"
        }
    }
}

extension View {
    public func deckImport(
        isPresented: Binding<Bool>,
        externalFile: Binding<URL?> = .constant(nil),
        onRefresh: @escaping () -> Void
    ) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented, externalFile: externalFile, onRefresh: onRefresh))
    }
}
