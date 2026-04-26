//
//  OpenTargetPayload.swift
//  Mos
//  "打开应用 / 运行脚本" 动作的持久化结构
//

import Foundation

/// 打开应用或运行脚本动作的结构化配置.
///
/// 设计目标: 自描述、可 AI 改写、可手编辑.
/// JSON 形态保持扁平, 字段名直白, 不依赖任何编码字符串.
struct OpenTargetPayload: Codable, Equatable {

    /// 文件绝对路径 (.app bundle 或脚本)
    let path: String

    /// .app 的 bundle identifier; 脚本恒为 nil
    /// 运行时优先使用此值解析 App, 即便 .app 被移动到别处也能找到
    let bundleID: String?

    /// 用户原始输入的参数字符串 (空字符串 = 无参数)
    /// 执行时按 shell 风格 split (支持双引号包裹和反斜杠转义)
    let arguments: String

    /// 是否按 .app 处理.
    /// 配置时显式存储, 不依赖运行时启发式 (避免 .app 被删后无法识别).
    let isApplication: Bool
}

/// shell 风格参数切分.
///
/// 规则:
/// - 按空白字符 (空格 / 制表符 / 换行) 分隔
/// - 双引号包裹的部分原样保留 (引号本身不进入结果)
/// - 反斜杠转义紧随其后的下一个字符 (不论是否在引号内)
/// - 末尾未闭合的引号: 视作 EOF 自动闭合, 不抛错
///
/// 例: `--port=3000 "with space" \"escaped\"` → `["--port=3000", "with space", "\"escaped\""]`
enum ArgumentSplitter {

    static func split(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = raw.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            // 反斜杠转义: 下一字符原样追加
            if scalar == "\\" {
                if let next = iterator.next() {
                    current.unicodeScalars.append(next)
                }
                continue
            }
            // 双引号: 切换状态, 引号本身不进入结果
            if scalar == "\"" {
                inQuotes.toggle()
                continue
            }
            // 引号外的空白: 切分边界
            if !inQuotes && CharacterSet.whitespaces.contains(scalar) {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
                continue
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }
}
