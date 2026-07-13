//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults
import SwiftUI

public enum Style {
    case notch
    case floating
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    case shelf
    case meeting
}

enum SettingsEnum {
    case general
    case about
    case charge
    case download
    case mediaPlayback
    case hud
    case shelf
    case extensions
}

enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
}

enum DownloadIconStyle: String, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}

enum MirrorShapeEnum: String, Defaults.Serializable {
    case rectangle = "Rectangular"
    case circle = "Circular"
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

// 触感反馈强度。macOS 系统触感 API 不支持连续强度，只能在固定模式间切换，
// 因此这里用两档来近似“普通/更深”的手感。
enum HapticStrength: String, CaseIterable, Defaults.Serializable {
    case light = "Light"
    case deep = "Deep"

    // 映射到 SwiftUI 的系统触感模式：轻=对齐反馈（单次轻点），深=层级变化（更明显的一下）
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .light: return .alignment
        case .deep: return .levelChange
        }
    }
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
}

// 会议录音音源（当前采集固定为双路混音，设置项预留以便后续接线）
enum MeetingAudioSource: String, CaseIterable, Defaults.Serializable {
    case both = "System + Microphone"
    case systemOnly = "System only"
    case micOnly = "Microphone only"
}
