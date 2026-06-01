import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Report export paths (App Sandbox)

/// Resolves sandbox-permitted report destinations instead of hard-coded home paths.
enum ReportExportPaths {
    static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    static func writeHTMLReport(
        _ html: String,
        fileName: String,
        to folderURL: URL,
        completion: (Result<URL, Error>) -> Void
    ) {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let destination = folderURL.appendingPathComponent(fileName)
        do {
            try html.write(to: destination, atomically: true, encoding: .utf8)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
        }
    }
}

final class ReportShareCoordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let fileURL: URL
    let onError: (String) -> Void
    let onFinish: () -> Void

    init(fileURL: URL, onError: @escaping (String) -> Void, onFinish: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onError = onError
        self.onFinish = onFinish
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        if sharingService.subject == nil || sharingService.subject?.isEmpty == true {
            sharingService.subject = "VEEAM BACKUP REPORT"
        }
        return self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        scheduleCleanupExportFile()
        onFinish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        onError("Report share failed: \(error.localizedDescription)")
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if let service {
            if service.subject == nil || service.subject?.isEmpty == true {
                service.subject = "VEEAM BACKUP REPORT"
            }
        } else {
            onFinish()
        }
    }

    func scheduleCleanupExportFile() {
        // Some share services (notably Messages) may still need the source file
        // briefly after didShareItems fires. Delay deletion to avoid empty sends.
        let fileURL = self.fileURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                self.onError("Report shared, but cleanup failed: \(error.localizedDescription)")
            }
        }
    }
}


