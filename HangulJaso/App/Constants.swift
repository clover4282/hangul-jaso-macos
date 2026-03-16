import Foundation

enum Constants {
    enum Defaults {
        static let watchedFoldersFileName = "watched_folders.json"
        static let registeredSettings: [String: Any] = [
            UserDefaultsKeys.notifyOnAutoConvert: true,
            UserDefaultsKeys.startAtLogin: false,
            UserDefaultsKeys.recursiveScan: true
        ]
    }

    enum UserDefaultsKeys {
        static let notifyOnAutoConvert = "notifyOnAutoConvert"
        static let startAtLogin = "startAtLogin"
        static let recursiveScan = "recursiveScan"
    }

    enum SharedDefaults {
        static let suiteName = "9P8DG7976Y.com.clover4282.hanguljaso"
        /// Key: directory path, Value: [String] array of NFC filenames that are NFD on disk
        static let nfdFilesKey = "nfdFiles"
        /// FinderSync → main app 변환 요청 경로 목록
        static let pendingConvertPathsKey = "pendingConvertPaths"
    }
}
