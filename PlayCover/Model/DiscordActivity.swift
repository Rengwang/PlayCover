//
//  DiscordActivity.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/07/16.
//

import Foundation

class DiscordActivity: Codable {
    var enable = false
    var applicationID = ""
    var details = ""
    var state = ""
    var image = ""

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        applicationID = try container.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
    }
}
