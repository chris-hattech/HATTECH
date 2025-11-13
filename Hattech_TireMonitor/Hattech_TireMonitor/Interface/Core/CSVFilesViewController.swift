import UIKit

/// Displays CSV files stored within the application's document directory.
final class CSVFilesViewController: UIViewController {
    private var csvFiles: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        loadCSVFiles()
    }

    /// Loads CSV files from the application's document directory.
    private func loadCSVFiles() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let enumerator = fileManager.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.nameKey, .isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let resourceKeys: Set<URLResourceKey> = [.nameKey, .isRegularFileKey]

        csvFiles.removeAll()

        while let case let fileURL as URL = enumerator?.nextObject() {
            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else { continue }
                if fileURL.pathExtension.lowercased() == "csv" {
                    csvFiles.append(fileURL)
                }
            } catch {
                // Ignore files that fail to load their resource values.
            }
        }
    }
}
