//
//  Item.swift
//  MyScreenStudio
//
//  Created by Ras Alungei on 10/8/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
