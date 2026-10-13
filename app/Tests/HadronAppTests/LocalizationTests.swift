import Foundation
import Testing

@testable import HadronApp

@Suite("Localization")
struct LocalizationTests {
    let chinese = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Chinese text is looked up with interpolated values in place")
    func chineseLookup() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Status", bundle: zh) == "状态")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: zh) == "删除 3 个游戏容器？")
    }

    @Test("Chinese text can put interpolated values in another order")
    func chineseReorders() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: zh)
            == "已在“Zuma Deluxe”中打开Wine Configuration。")
    }
}
