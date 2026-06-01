import Foundation

// MARK: - Private API decode types

struct JobState: Decodable {
    let id: String
    let name: String
    let type: String?
    let status: String?
    let lastResult: String?
    let lastRun: Date?
    let nextRun: Date?
    let nextRunPolicy: String?
    let runAfterJob: RunAfterJob?
    let isEnabled: Bool?
    let repositoryName: String?
    let objectsCount: Int?
    let progressPercent: Int?
    let sessionProgress: SessionProgress?
    let sessionId: String?

    struct RunAfterJob: Decodable {
        let jobName: String?
        let jobId: String?
    }

    struct SessionProgress: Decodable {
        let progressPercent: Int?
        let processingRate: String?
        let processedSize: Int64?
        let readSize: Int64?
        let transferredSize: Int64?
    }
}

struct JobStatesResponse: Decodable {
    let data: [JobState]
    let pagination: PaginationInfo?
}
struct PaginationInfo: Decodable {
    let total: Int
    let count: Int
    let skip: Int
    let limit: Int
}

struct JobConfig: Decodable {
    let id: String
    let description: String?
    let isDisabled: Bool?
    let schedule: Schedule?
    let virtualMachines: VirtualMachines?
    let storage: Storage?

    private enum CodingKeys: String, CodingKey {
        case id
        case uid = "UID"
        case description
        case Description
        case isDisabled
        case schedule
        case jobScheduleOptions = "JobScheduleOptions"
        case virtualMachines
        case storage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
        } else if let uid = try container.decodeIfPresent(String.self, forKey: .uid) {
            self.id = uid
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing job identifier")
            )
        }
        description =
            try container.decodeIfPresent(String.self, forKey: .description) ??
            container.decodeIfPresent(String.self, forKey: .Description)

        if let schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule) {
            self.schedule = schedule
        } else if let jobScheduleOptions = try container.decodeIfPresent(JobScheduleOptions.self, forKey: .jobScheduleOptions) {
            self.schedule = jobScheduleOptions.standard ?? jobScheduleOptions.fallback
        } else {
            self.schedule = nil
        }

        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled)
        virtualMachines = try container.decodeIfPresent(VirtualMachines.self, forKey: .virtualMachines)
        storage = try container.decodeIfPresent(Storage.self, forKey: .storage)
    }

    private struct JobScheduleOptions: Decodable {
        let standard: Schedule?
        let fallback: Schedule?

        private enum CodingKeys: String, CodingKey {
            case standard = "Standard"
            case standart = "Standart"
            case optionsDaisyChaining = "OptionsDaisyChaining"
            case optionsContinuous = "OptionsContinuous"
            case optionsDaily = "OptionsDaily"
            case optionsWeekly = "OptionsWeekly"
            case optionsMonthly = "OptionsMonthly"
            case optionsPeriodically = "OptionsPeriodically"
            case runAutomatically = "RunAutomatically"
            case waitForBackupCompletion = "WaitForBackupCompletion"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            standard =
                try container.decodeIfPresent(Schedule.self, forKey: .standard) ??
                container.decodeIfPresent(Schedule.self, forKey: .standart)

            if standard == nil {
                fallback = try? Schedule(from: decoder)
            } else {
                fallback = nil
            }
        }
    }

    struct Schedule: Decodable {
        let runAutomatically: Bool?
        let daily: Daily?
        let weekly: Weekly?
        let monthly: Monthly?
        let periodically: Periodically?
        let continuously: Continuous?
        let continuous: Continuous?
        let optionsDaisyChaining: DaisyChaining?
        let afterThisJob: AfterThisJob?

        private enum CodingKeys: String, CodingKey {
            case runAutomatically
            case schedulePolicyType
            case daily
            case weekly
            case monthly
            case periodically
            case continuously
            case continuous
            case optionsDaisyChaining
            case afterThisJob
            case RunAutomatically
            case OptionsDaily
            case OptionsWeekly
            case OptionsMonthly
            case OptionsPeriodically
            case OptionsContinuous
            case OptionsDaisyChaining
            case AfterThisJob
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runAutomatically =
                try container.decodeIfPresent(Bool.self, forKey: .runAutomatically) ??
                container.decodeIfPresent(Bool.self, forKey: .RunAutomatically)
            daily =
                try container.decodeIfPresent(Daily.self, forKey: .daily) ??
                container.decodeIfPresent(Daily.self, forKey: .OptionsDaily)
            weekly =
                try container.decodeIfPresent(Weekly.self, forKey: .weekly) ??
                container.decodeIfPresent(Weekly.self, forKey: .OptionsWeekly)
            monthly =
                try container.decodeIfPresent(Monthly.self, forKey: .monthly) ??
                container.decodeIfPresent(Monthly.self, forKey: .OptionsMonthly)
            periodically =
                try container.decodeIfPresent(Periodically.self, forKey: .periodically) ??
                container.decodeIfPresent(Periodically.self, forKey: .OptionsPeriodically)
            continuously =
                try container.decodeIfPresent(Continuous.self, forKey: .continuously)
            continuous =
                try container.decodeIfPresent(Continuous.self, forKey: .continuous) ??
                container.decodeIfPresent(Continuous.self, forKey: .OptionsContinuous)
            optionsDaisyChaining =
                try container.decodeIfPresent(DaisyChaining.self, forKey: .optionsDaisyChaining) ??
                container.decodeIfPresent(DaisyChaining.self, forKey: .OptionsDaisyChaining)
            afterThisJob =
                try container.decodeIfPresent(AfterThisJob.self, forKey: .afterThisJob) ??
                container.decodeIfPresent(AfterThisJob.self, forKey: .AfterThisJob)
        }

        struct Daily: Decodable {
            let isEnabled: Bool?
            let dailyKind: String?  // "Everyday", "Workdays", "Weekends", "SelectedDays"
            let time: String?       // "22:00:00"

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case dailyKind
                case time
                case Enabled
                case Kind
                case Time
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                dailyKind =
                    try container.decodeIfPresent(String.self, forKey: .dailyKind) ??
                    container.decodeIfPresent(String.self, forKey: .Kind)
                time =
                    try container.decodeIfPresent(String.self, forKey: .time) ??
                    container.decodeIfPresent(String.self, forKey: .Time)
            }
        }

        struct Weekly: Decodable {
            let isEnabled: Bool?
            let dayOfWeek: [String]?
            let time: String?

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case dayOfWeek
                case time
                case Enabled
                case Days
                case Time
                case DayOfWeek
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                dayOfWeek =
                    try container.decodeIfPresent([String].self, forKey: .dayOfWeek) ??
                    container.decodeIfPresent([String].self, forKey: .Days) ??
                    Self.decodeSingleDay(from: container)
                time =
                    try container.decodeIfPresent(String.self, forKey: .time) ??
                    container.decodeIfPresent(String.self, forKey: .Time)
            }

            private static func decodeSingleDay(from container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
                if let singleDay = try? container.decode(String.self, forKey: .DayOfWeek) {
                    return [singleDay]
                }

                return nil
            }
        }

        struct Monthly: Decodable {
            let isEnabled: Bool?
            let time: String?

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case time
                case Enabled
                case Time
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                time =
                    try container.decodeIfPresent(String.self, forKey: .time) ??
                    container.decodeIfPresent(String.self, forKey: .Time)
            }
        }

        struct Periodically: Decodable {
            let isEnabled: Bool?
            let frequency: Int?
            let frequencyTimeUnit: String?  // "Hours", "Minutes"

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case frequency
                case frequencyTimeUnit
                case Enabled
                case FullPeriod
                case Kind
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                frequency =
                    try container.decodeIfPresent(Int.self, forKey: .frequency) ??
                    container.decodeIfPresent(Int.self, forKey: .FullPeriod)
                frequencyTimeUnit =
                    try container.decodeIfPresent(String.self, forKey: .frequencyTimeUnit) ??
                    container.decodeIfPresent(String.self, forKey: .Kind)
            }
        }

        struct Continuous: Decodable {
            let isEnabled: Bool?

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case Enabled
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
            }
        }

        struct DaisyChaining: Decodable {
            let enabled: Bool?
            let previousJobUid: String?

            private enum CodingKeys: String, CodingKey {
                case enabled
                case previousJobUid
                case Enabled
                case PreviousJobUid
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled =
                    try container.decodeIfPresent(Bool.self, forKey: .enabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                previousJobUid =
                    try container.decodeIfPresent(String.self, forKey: .previousJobUid) ??
                    container.decodeIfPresent(String.self, forKey: .PreviousJobUid)
            }
        }

        struct AfterThisJob: Decodable {
            let isEnabled: Bool?
            let jobName: String?

            private enum CodingKeys: String, CodingKey {
                case isEnabled
                case jobName
                case Enabled
                case JobName
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled =
                    try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ??
                    container.decodeIfPresent(Bool.self, forKey: .Enabled)
                jobName =
                    try container.decodeIfPresent(String.self, forKey: .jobName) ??
                    container.decodeIfPresent(String.self, forKey: .JobName)
            }
        }
    }

    struct VirtualMachines: Decodable {
        let includes: [IncludedVM]
        let excludes: Excludes?

        struct IncludedVM: Decodable {
            let name: String?
            let size: String?
        }

        struct Excludes: Decodable {
            let disks: [DiskSelection]?

            struct DiskSelection: Decodable {
                let disksToProcess: String?
                let disks: [SelectedDisk]?

                struct SelectedDisk: Decodable {
                    let name: String?
                }
            }
        }
    }

    struct Storage: Decodable {
        let gfsPolicy: GFSPolicy?

        struct GFSPolicy: Decodable {
            let isEnabled: Bool?
            let weekly: Weekly?
            let monthly: Monthly?
            let yearly: Yearly?

            struct Weekly: Decodable {
                let desiredTime: String?
                let isEnabled: Bool?
            }

            struct Monthly: Decodable {
                let desiredTime: String?
                let isEnabled: Bool?
            }

            struct Yearly: Decodable {
                let desiredTime: String?
                let isEnabled: Bool?
            }
        }
    }
}

struct JobConfigResponse: Decodable {
    let data: JobConfig?

    init(from decoder: Decoder) throws {
        if let singleValue = try? JobConfig(from: decoder) {
            data = singleValue
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(JobConfig.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

struct BackupRecord: Decodable {
    let id: String
    let jobId: String?
    let name: String
    let platformName: String?
    let repositoryName: String?
}

struct BackupRecordsResponse: Decodable {
    let data: [BackupRecord]
    let pagination: PaginationInfo?
}

struct BackupObject: Decodable {
    let id: String
    let name: String
    let restorePointsCount: Int?
}

struct BackupObjectsResponse: Decodable {
    let data: [BackupObject]
    let pagination: PaginationInfo?
}

struct BackupFileRecord: Decodable {
    let id: String
    let name: String
    let backupId: String
    let objectId: String?
    let restorePointIds: [String]?
    let gfsPeriods: [String]?
    let immutableUntil: Date?
    let backupSize: Int64?
    let creationTime: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case backupId
        case objectId
        case restorePointIds
        case gfsPeriods
        case backupSize
        case creationTime
        case immutableUntil
        case immutabilityUntil
        case immutableTill
        case immutableUntilDate
        case immutabilityExpirationTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        backupId = try container.decode(String.self, forKey: .backupId)
        objectId = try container.decodeIfPresent(String.self, forKey: .objectId)
        restorePointIds = try container.decodeIfPresent([String].self, forKey: .restorePointIds)
        gfsPeriods = try container.decodeIfPresent([String].self, forKey: .gfsPeriods)
        backupSize = try container.decodeIfPresent(Int64.self, forKey: .backupSize)
        creationTime = try container.decodeIfPresent(Date.self, forKey: .creationTime)
        immutableUntil =
            Self.decodeFlexibleDate(from: container, keys: [
                .immutableUntil,
                .immutabilityUntil,
                .immutableTill,
                .immutableUntilDate,
                .immutabilityExpirationTime
            ])
    }

    private static func decodeFlexibleDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Date? {
        for key in keys {
            if let date = (try? container.decodeIfPresent(Date.self, forKey: key)) ?? nil {
                return date
            }
            if let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil,
               let parsed = parseDate(raw) {
                return parsed
            }
        }
        return nil
    }

    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: value) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formats = [
            "M/d/yyyy h:mm:ss a",
            "M/d/yyyy h:mm a",
            "M/d/yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}

struct BackupFilesResponse: Decodable {
    let data: [BackupFileRecord]
    let pagination: PaginationInfo?
}

struct RestorePointRecord: Decodable {
    let id: String
    let name: String
    let type: String
    let malwareStatus: String?
    let creationTime: Date
    let backupId: String
    let platformId: String?
    let originalSize: Int64?
    let expirationDate: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case malwareStatus
        case creationTime
        case backupId
        case platformId
        case originalSize
        case expirationDate
        case expirationTime
        case retainUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        malwareStatus = try container.decodeIfPresent(String.self, forKey: .malwareStatus)
        creationTime = try container.decode(Date.self, forKey: .creationTime)
        backupId = try container.decode(String.self, forKey: .backupId)
        platformId = try container.decodeIfPresent(String.self, forKey: .platformId)
        originalSize = try container.decodeIfPresent(Int64.self, forKey: .originalSize)
        expirationDate =
            try container.decodeIfPresent(Date.self, forKey: .expirationDate) ??
            container.decodeIfPresent(Date.self, forKey: .expirationTime) ??
            container.decodeIfPresent(Date.self, forKey: .retainUntil)
    }
}

struct RestorePointsResponse: Decodable {
    let data: [RestorePointRecord]
    let pagination: PaginationInfo?
}

struct SessionsResponse: Decodable {
    let data: [SessionRecord]
    let pagination: PaginationInfo?
}

struct GenericSessionsResponse: Decodable {
    let data: [[String: AnyCodableValue]]
}

struct SessionRecord: Decodable {
    let id: String
    let name: String?
    let jobId: String?
    let sessionType: String?
    let creationTime: Date?
    let endTime: Date?
    let status: String?
    let state: String?
    let progressPercent: Int?
    let result: SessionResultRecord?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sessionName
        case jobId
        case jobUid
        case sessionType
        case SessionType
        case type
        case creationTime
        case startTime
        case StartTime
        case endTime
        case stopTime
        case EndTime
        case status
        case state
        case progressPercent
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name =
            try container.decodeIfPresent(String.self, forKey: .name) ??
            container.decodeIfPresent(String.self, forKey: .sessionName)
        jobId =
            try container.decodeIfPresent(String.self, forKey: .jobId) ??
            container.decodeIfPresent(String.self, forKey: .jobUid)
        sessionType =
            try container.decodeIfPresent(String.self, forKey: .sessionType) ??
            container.decodeIfPresent(String.self, forKey: .SessionType) ??
            container.decodeIfPresent(String.self, forKey: .type)
        creationTime =
            try container.decodeIfPresent(Date.self, forKey: .creationTime) ??
            container.decodeIfPresent(Date.self, forKey: .startTime) ??
            container.decodeIfPresent(Date.self, forKey: .StartTime)
        endTime =
            try container.decodeIfPresent(Date.self, forKey: .endTime) ??
            container.decodeIfPresent(Date.self, forKey: .stopTime) ??
            container.decodeIfPresent(Date.self, forKey: .EndTime)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        progressPercent = try container.decodeIfPresent(Int.self, forKey: .progressPercent)
        result = try container.decodeIfPresent(SessionResultRecord.self, forKey: .result)
    }

    init(
        id: String,
        name: String?,
        jobId: String?,
        sessionType: String?,
        creationTime: Date?,
        endTime: Date?,
        status: String?,
        state: String?,
        progressPercent: Int?,
        result: SessionResultRecord?
    ) {
        self.id = id
        self.name = name
        self.jobId = jobId
        self.sessionType = sessionType
        self.creationTime = creationTime
        self.endTime = endTime
        self.status = status
        self.state = state
        self.progressPercent = progressPercent
        self.result = result
    }
}

struct SessionResultRecord: Decodable {
    let result: String?
    let message: String?
}

struct SessionLogsResponse: Decodable {
    let totalRecords: Int?
    let records: [SessionLogRecord]
}

struct SessionLogRecord: Decodable {
    let id: Int?
    let status: String?
    let startTime: Date?
    let updateTime: Date?
    let title: String?
    let description: String?
    let additionalInfo: String?
}

struct RestorePointDisksResponse: Decodable {
    let data: [RestorePointDiskRecord]
}

struct RestorePointDiskRecord: Decodable {
    let uid: String
    let type: String?
    let name: String?
    let capacity: Int64?
    let state: String?
}

struct VeeamTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct VeeamErrorResponse: Decodable {
    let errorCode: String?
    let message: String?
    let resourceId: String?
    let errors: [String]?

    enum CodingKeys: String, CodingKey {
        case errorCode
        case message
        case resourceId = "resourceId"
        case errors
    }
}

struct LoginAttemptResult {
    let data: Data
    let response: HTTPURLResponse
    let apiVersion: String
}

struct BackupPointMetadata {
    var gfsFlags: [String]
    var immutableUntil: Date?
    var backupSizeBytes: Int64?
    var backupSetName: String?
    var backupSetCreatedAt: Date?
}

struct GenericBackupFilesPage: Decodable {
    let data: [[String: AnyCodableValue]]
}

enum AnyCodableValue: Decodable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }
}

struct MFAChallenge {
    let token: String?
    let message: String?
}

enum LoginGrantMode {
    case password
    case authorizationCode
    case vbrToken
    case refreshToken
}

