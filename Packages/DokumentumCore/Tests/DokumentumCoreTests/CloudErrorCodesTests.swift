import CloudKit
import DokumentumKit
import Foundation
import Testing

@testable import DokumentumCore

/// Kit spells CloudKit's codes and keys out, so that it builds on Linux; these pin them against the SDK (plan of #31,
/// P-a).
struct CloudErrorCodesTests {
    private func classify(_ code: CKError.Code) -> CloudErrorCategory {
        CloudErrorCategory.classify([ErrorLink(domain: CKError.errorDomain, code: code.rawValue)])
    }

    @Test func kitsConstantsAreTheSDKs() {
        #expect(CloudErrorCategory.cloudKitDomain == CKError.errorDomain)
        #expect(CloudErrorCategory.partialFailure == CKError.Code.partialFailure.rawValue)
        #expect(CloudErrorCategory.networkUnavailable == CKError.Code.networkUnavailable.rawValue)
        #expect(CloudErrorCategory.networkFailure == CKError.Code.networkFailure.rawValue)
        #expect(CloudErrorCategory.notAuthenticated == CKError.Code.notAuthenticated.rawValue)
        #expect(CloudErrorCategory.quotaExceeded == CKError.Code.quotaExceeded.rawValue)
        #expect(CloudErrorCategory.zoneNotFound == CKError.Code.zoneNotFound.rawValue)
        #expect(CloudErrorCategory.userDeletedZone == CKError.Code.userDeletedZone.rawValue)
        #expect(CloudErrorCategory.accountTemporarilyUnavailable == CKError.Code.accountTemporarilyUnavailable.rawValue)
        #expect(CloudSyncEvents.partialErrorsKey == CKPartialErrorsByItemIDKey)
        #expect(CKDomain.name == CKError.errorDomain)
    }

    @Test func eachSDKCodeHasItsCategory() {
        #expect(classify(.quotaExceeded) == .storageFull)
        #expect(classify(.notAuthenticated) == .noAccount)
        #expect(classify(.accountTemporarilyUnavailable) == .accountUnavailable)
        #expect(classify(.networkUnavailable) == .offline)
        #expect(classify(.networkFailure) == .offline)
        #expect(classify(.zoneNotFound) == .reset)
        #expect(classify(.userDeletedZone) == .reset)
        #expect(classify(.serverRecordChanged) == .other)
    }

    @Test func aCKErrorWithPartialFailuresIsFlattened() {
        let item = CKError(.quotaExceeded)
        let error = CKError(
            .partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "r"): item]])
        let chain = CloudSyncEvents.errorChain(of: error)
        #expect(chain.map(\.code) == [CKError.Code.partialFailure.rawValue, CKError.Code.quotaExceeded.rawValue])
        #expect(CloudErrorCategory.classify(chain) == .storageFull)
    }

    @Test(arguments: [
        (CKAccountStatus.available, AccountState.available),
        (.noAccount, .noAccount),
        (.restricted, .restricted),
        (.couldNotDetermine, .couldNotDetermine),
        (.temporarilyUnavailable, .temporarilyUnavailable),
    ])
    func eachAccountStatusHasItsState(status: CKAccountStatus, state: AccountState) {
        #expect(CloudKitAccountStatus.state(of: status) == state)
    }
}
