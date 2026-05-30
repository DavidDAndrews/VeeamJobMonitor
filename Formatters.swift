import Foundation

// MARK: - Formatters

final class RelativeTimeFormatter: RelativeDateTimeFormatter, @unchecked Sendable {
    static let shared: RelativeTimeFormatter = {
        let f = RelativeTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

final class DetailDateFormatter: DateFormatter, @unchecked Sendable {
    static let shared: DetailDateFormatter = {
        let f = DetailDateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

final class DetailTimeFormatter: DateFormatter, @unchecked Sendable {
    static let shared: DetailTimeFormatter = {
        let f = DetailTimeFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

final class BackupPointDateFormatter: DateFormatter, @unchecked Sendable {
    static let shared: BackupPointDateFormatter = {
        let f = BackupPointDateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

