//
//  DebugSessionLog.swift
//  boringNotch
//
//  会议模块调试日志。合并进 boring.notch 后已降噪为无副作用实现：
//  不再写死工作区路径、不再向 localhost 上报，仅在需要时输出到系统日志。
//

import Foundation

enum DebugSessionLog {
    /// 是否输出到系统日志（默认关闭，避免生产环境噪声）
    private static let verbose = false

    static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "prod"
    ) {
        guard verbose else { return }
        NSLog("[Meeting][\(location)] \(message) \(data)")
    }
}
