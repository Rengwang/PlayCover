import AudioToolbox
import Foundation
import SwiftUI

enum PlayCoverError: Error {
    case infoPlistNotFound
    case waitInstallation
    case waitDownload
    case appEncrypted
    case appCorrupted
    case marketplaceKitUnavailable
    case hostDependencyUnavailable(path: String, image: String)
    case appRunningDuringInstall
    case appProhibited
    case appMaliciousProhibited
    case failedToStripBinary
    case invalidUserDylib
}

extension PlayCoverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .infoPlistNotFound:
            return NSLocalizedString("error.corruptedIPA", comment: "")
        case .waitInstallation:
            return NSLocalizedString("error.waitInstallation", comment: "")
        case .waitDownload:
            return NSLocalizedString("error.waitDownload", comment: "")
        case .appEncrypted:
            return NSLocalizedString("error.appEncrypted", comment: "")
        case .appCorrupted:
            return NSLocalizedString("error.appCorrupted", comment: "")
        case .marketplaceKitUnavailable:
            return NSLocalizedString("error.marketplaceKitUnavailable", comment: "")
        case let .hostDependencyUnavailable(path, image):
            return String(format: NSLocalizedString("error.hostDependencyUnavailable", comment: ""), image, path)
        case .appRunningDuringInstall:
            return NSLocalizedString("error.appRunningDuringInstall", comment: "")
        case .appProhibited:
            return NSLocalizedString("error.appProhibited", comment: "")
        case .appMaliciousProhibited:
            return NSLocalizedString("error.appMaliciousProhibited", comment: "")
        case .failedToStripBinary:
            return NSLocalizedString("error.failedToStripBinary", comment: "")
        case .invalidUserDylib:
            return NSLocalizedString("error.invalidUserDylib", comment: "")
        }
    }
}
