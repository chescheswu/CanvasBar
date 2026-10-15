// CanvasBar — macOS 菜单栏 Canvas 课业同步工作台 (v2.8)
// 课程列表 → 一键开同步文件夹 / 在 Canvas 打开课程页；自动同步 Canvas 材料（模块 ∪ 公告附件 ∪ 页面正文引用，含 front_page）→ ~/Documents/Canvas 同步/<课程>/；
// 库内去重；跳过视频/大文件（保留在线链接）；DDL 可标记已提交/手动添加（选课程+日期）；每课新内容角标；按课程勾选同步；课程子菜单列出已同步文件（悬停展开、点击直开）+ 在 Canvas 打开课程；开机自启；应用图标（Canvas 花标，对话框/Finder 显示）
// v2.7：子菜单按用户整理的文件夹结构展示（磁盘实时扫描）；子菜单可「关闭/恢复该课程同步」（关闭需确认，已下载文件保留）；单独同步某课程；登录窗健壮化（弹窗/重定向收敛到应用内、SAML 递交协助、登录态 Cookie 变化检测、登录窗手动关闭回退）
// v2.8：登录态持久化——会话检查「快路 + SSO 静默重登」（Canvas session 过期时靠 ADFS 持久 cookie 自动回流，不再动辄弹登录窗）；30 分钟心跳保活（应用运行期间会话不再空闲过期）；登录页「保持登录」复选框自动勾选
// v2.9：文件子菜单改「操作组」——打开（默认）/ 打开方式（系统可用 App 列表 + 其他…）/ 在 Finder 中显示（目录同）；新增「⬆️ 检查更新…」+ 一键更新（连 GitHub Releases：下载 zip → ditto 解压 → 版本 + 签名校验 → 后台脚本替换并重启）
// 运行时配置：~/Library/Application Support/CanvasBar/config.json（Canvas 域名，便于分发他机使用）
import AppKit
import SwiftUI
import WebKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - 常量

// ★ 唯一写入边界：插件所有下载统一落在 ~/Documents/Canvas 同步/，不碰用户其他目录
let syncRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/Canvas 同步", isDirectory: true)

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CanvasBar", isDirectory: true)

let logURL = supportDir.appendingPathComponent("log.txt")

// MARK: - 运行时配置（config.json 可改 Canvas 域名；换学校/换机器只动这里）

enum Cfg {
    static let defaultOrigin = "https://canvas.polyu.edu.hk"
    static private(set) var origin = defaultOrigin
    static private(set) var host: String = URL(string: defaultOrigin)?.host ?? ""

    static var configURL: URL { supportDir.appendingPathComponent("config.json") }

    static func load() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = obj["canvasOrigin"] as? String else { return }
        apply(o)
    }

    static func apply(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let h = URL(string: s)?.host, !h.isEmpty else { return }
        origin = s
        host = h
    }

    static func save(origin raw: String) {
        apply(raw)
        let obj: [String: String] = ["canvasOrigin": origin]
        if let d = try? JSONSerialization.data(withJSONObject: obj,
                                               options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: configURL, options: .atomic)
        }
    }
}

func log(_ s: String) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8) ?? Data())
        try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: logURL)
    }
}

/// 日志裁剪：超过 512KB 时只保留尾部 128KB（防无限增长）
func trimLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let size = attrs[.size] as? NSNumber, size.intValue > 512 * 1024,
          let data = try? Data(contentsOf: logURL) else { return }
    let tailTarget = 128 * 1024
    guard data.count > tailTarget else { return }
    let cut = data.suffix(tailTarget)
    if let nl = cut.firstIndex(of: 0x0A) {
        let trimmed = cut.suffix(from: cut.index(after: nl))
        try? trimmed.write(to: logURL)
    }
}

func isCanvasURL(_ url: URL?) -> Bool {
    (url?.host ?? "").contains(Cfg.host)
}

/// 自动化触发：在同步库里放一个 .sync-now 文件 → 启动/定时检查时触发一次同步（用完即删）
func consumeSyncRequest() -> Bool {
    let marker = syncRoot.appendingPathComponent(".sync-now")
    guard FileManager.default.fileExists(atPath: marker.path) else { return false }
    try? FileManager.default.removeItem(at: marker)
    log("检测到 .sync-now，触发一次同步")
    return true
}

/// DDL 兜底链接：planner 不带 html_url 时按类型拼 Canvas 页面地址
func ddlFallbackURL(_ e: UpcomingEvent) -> String? {
    guard let pid = e.evid, !pid.isEmpty, !e.context.isEmpty else { return nil }
    switch e.ptype ?? "" {
    case "assignment": return "\(Cfg.origin)/courses/\(e.context)/assignments/\(pid)"
    case "quiz": return "\(Cfg.origin)/courses/\(e.context)/quizzes/\(pid)"
    case "discussion_topic": return "\(Cfg.origin)/courses/\(e.context)/discussion_topics/\(pid)"
    default: return "\(Cfg.origin)/courses/\(e.context)"
    }
}

// 课程 id → 菜单显示名（简短、Title Case；仅本机显示优化，缺失时自动生成，不影响跨机一致性）
let displayOverrides: [Int64: String] = [
    6306: "Artificial Intelligence Concepts",
    3689: "Computer Programming in L&C",
    3691: "Digital Studies of Chinese Culture",
    3690: "Intro to Generative AI",
    4452: "Machine Learning & Data Analytics",
    3688: "The Ethical Context of GenAI",
    3445: "Understanding China and HK SAR",
    5470: "IT Security Training",
    3415: "Academic Integrity Tutorial",
]

func sanitizeName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/:*?\"<>|")
    return s.components(separatedBy: bad).joined(separator: "／")
}

/// Title Case：全小写后逐词首字母大写，保留短介词/连词小写
func titleCased(_ s: String) -> String {
    let small: Set<String> = ["a", "an", "and", "of", "the", "in", "to", "for", "on", "at", "by", "with", "&", "into"]
    let words = s.lowercased().split(separator: " ").map(String.init)
    var out: [String] = []
    for (i, w) in words.enumerated() {
        if i > 0 && i < words.count - 1 && small.contains(w) {
            out.append(w)
        } else if let f = w.first {
            out.append(f.uppercased() + w.dropFirst())
        }
    }
    return out.joined(separator: " ")
}

/// 显示名：去尾部括号段 → Title Case → 超长截断
func shortName(_ raw: String) -> String {
    var s = raw
    while let r = s.range(of: #"[\(（][^\(\)（）]*[\)）]\s*$"#, options: .regularExpression) {
        s.removeSubrange(r)
        s = s.trimmingCharacters(in: .whitespaces)
    }
    s = titleCased(s)
    if s.count > 46 { s = String(s.prefix(44)) + "…" }
    return s
}

/// 同步库内的课程子文件夹名：由显示名自动生成（跨机一致，不绑定任何本机旧路径）
func courseFolderName(_ display: String) -> String {
    var s = display
    while s.hasSuffix("…") || s.hasSuffix(" ") { s.removeLast() }
    s = sanitizeName(s)
    return s.isEmpty ? "Untitled Course" : s
}

// MARK: - 跳过过滤（视频 / 超大文件）

let bigFileLimitMB = 300
let videoExts: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "webm",
                              "mpg", "mpeg", "3gp", "ts", "flv", "rmvb", "rm"]

func isVideoFile(_ name: String) -> Bool {
    videoExts.contains((name as NSString).pathExtension.lowercased())
}

enum SkipKind { case video, big }

struct SkippedFile: Error {
    let kind: SkipKind
    let name: String
    let size: Int64
}

/// 结果盒子：后台线程写、主线程读（只做简单的 done 标记同步）
final class Box<T>: @unchecked Sendable {
    var value: T?
    var done = false
}

/// 同步库实时扫描出的一个文件（相对课程文件夹的子目录路径 + 文件名 + 绝对路径）
struct LibEntry {
    let dirs: [String]     // 相对子目录（[] = 课程文件夹根下）
    let name: String
    let path: String
}

/// 课程子菜单的树节点：目录（path=nil）或文件
struct MenuNode: Identifiable {
    let id: String
    let name: String
    let path: String?       // 文件路径；目录为 nil
    let fid: String?        // manifest 文件 id（可能为 nil）
    let children: [MenuNode]
    var isDir: Bool { path == nil }
}

// MARK: - 数据

struct CachedCourse: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String        // 菜单显示名（短）
    let folder: String      // 本地文件夹名
    var url: URL { syncRoot.appendingPathComponent(folder, isDirectory: true) }
}

// 无首启种子：课程列表完全来自 Canvas 实际选课（登录一次即自动获取，跨机器可复现）

struct ManFile: Codable {
    var name: String
    var size: Int64
    var path: String
}
typealias Manifest = [String: [String: ManFile]]

/// 课程里的外部链接（如老师的 Google Drive 课件夹）：只展示、一键用浏览器打开，不下载
struct ExternalLink: Codable, Identifiable, Hashable {
    let title: String
    let url: String
    var id: String { url }
}
typealias LinkMap = [String: [ExternalLink]]

struct SyncState: Codable {
    var lastSync: Date?
    var upcoming: [UpcomingEvent]?
    var skipVideos: Bool?               // 跳过视频（写 .webloc 在线链接）
    var skipBig: Bool?                  // 跳过超大文件
    var ddlDone: [String]?              // 已标记「已提交」的 DDL key
    var newFiles: [String: [String]]?   // courseId → 上次查看后的新增文件名
    var syncDisabled: [Int64]?          // 未勾选同步的课程 id
    var manual: [ManualDdl]?            // 手动添加的 DDL（选课程 + 日期）
}

struct UpcomingEvent: Codable, Identifiable, Hashable {
    let title: String
    let due: String          // ISO8601
    let context: String      // 课程 id 字符串
    var evid: String?        // Canvas plannable_id（稳定，用于「已提交」标记）
    var url: String?         // Canvas 页面链接（缺失时按类型兜底拼接）
    var submitted: Bool?     // Canvas 侧已提交 → 自动不再提醒
    var ptype: String?       // plannable_type（assignment / quiz / …）

    var id: String {
        if let e = evid, !e.isEmpty { return e }
        return title + "|" + due
    }

    var dueDate: Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: due) { return d }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: due)
    }

    var daysLeft: Int? {
        guard let d = dueDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: Date()),
                                  to: cal.startOfDay(for: d)).day
    }

    var dueText: String {
        guard let d = dueDate else { return due }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// 手动添加的 DDL（不依赖 Canvas；courseId=0 表示未指定课程）
struct ManualDdl: Codable, Identifiable, Hashable {
    var uid: String = UUID().uuidString
    var title: String
    var courseId: Int64
    var due: String              // ISO8601
    var id: String { uid }

    var event: UpcomingEvent {
        UpcomingEvent(title: title, due: due,
                      context: courseId == 0 ? "" : String(courseId),
                      evid: "manual-\(uid)", url: nil, submitted: false, ptype: "manual")
    }
}

// MARK: - 开机自启

enum AutoStart {
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.chester.canvasbar.plist")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentPlist.path)
    }

    static func set(_ on: Bool) {
        if on {
            do {
                try SMAppService.mainApp.register()
                log("开机自启：SMAppService 注册成功")
                try? FileManager.default.removeItem(at: agentPlist)
                return
            } catch {
                log("SMAppService 注册失败（\(error.localizedDescription)），改用 LaunchAgent")
            }
            writeAgent()
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentPlist)
            log("开机自启：已关闭")
        }
    }

    static func writeAgent() {
        let bin = Bundle.main.bundlePath + "/Contents/MacOS/CanvasBar"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>local.chester.canvasbar</string>
            <key>ProgramArguments</key><array><string>\(bin)</string></array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try plist.write(to: agentPlist, atomically: true, encoding: .utf8)
            log("开机自启：LaunchAgent 已写入 \(agentPlist.path)")
        } catch {
            log("LaunchAgent 写入失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var courses: [CachedCourse] = []
    @Published var progress: String = ""
    @Published var isSyncing = false
    @Published var lastSync: Date?
    @Published var upcoming: [UpcomingEvent] = []
    @Published var autoStartOn: Bool = AutoStart.isEnabled
    @Published var skipVideos = true
    @Published var skipBig = true
    @Published var ddlDone: [String] = []
    @Published var newFiles: [Int64: [String]] = [:]
    @Published var syncDisabled: Set<Int64> = []
    @Published var manualDdl: [ManualDdl] = []
    @Published var manifest: Manifest = [:]   // 课程子菜单文件索引（启动 / 同步后刷新）
    @Published var links: LinkMap = [:]       // 课程子菜单外部链接（Google Drive 等）
    @Published var libTree: [Int64: [LibEntry]] = [:]   // 课程文件夹实时结构（含用户整理出的子文件夹）
    private var libRefreshInFlight = false
    private var libLastRefresh: Date?

    init() {
        loadCache()
        migrateFoldersIfNeeded()
        reloadManifest()
        reloadLinks()
    }

    /// v2 迁移：课程子文件夹名统一 = 显示名（同步库结构为 Canvas 同步/<显示名>/）
    private func migrateFoldersIfNeeded() {
        guard !courses.isEmpty else { return }
        var used = Set<String>()
        let fixed = courses.map { c -> CachedCourse in
            var f = courseFolderName(c.name)
            var n = 2
            while used.contains(f) {
                f = courseFolderName(c.name) + " \(n)"
                n += 1
            }
            used.insert(f)
            return CachedCourse(id: c.id, name: c.name, folder: f)
        }
        if fixed != courses {
            courses = fixed
            saveCourses()
        }
    }

    var lastSyncText: String {
        guard let d = lastSync else { return "尚未同步" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "上次同步 " + f.string(from: d)
    }

    /// 手动 DDL 转成事件（与 Canvas DDL 统一排序 / 提醒）
    var manualEvents: [UpcomingEvent] { manualDdl.map(\.event) }

    func isManualDdl(_ e: UpcomingEvent) -> Bool { (e.evid ?? "").hasPrefix("manual-") }

    /// 未提交、未被标记「已提交」的 DDL（Canvas 同步 + 手动）
    var activeUpcoming: [UpcomingEvent] {
        (upcoming + manualEvents).filter { e in
            if e.submitted == true { return false }
            return !ddlDone.contains(e.id)
        }
    }

    var upcomingSoon: [UpcomingEvent] {
        activeUpcoming
            .filter { ($0.daysLeft ?? -1) >= 0 }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// 菜单栏标签：最近 DDL 剩余天数
    var nearestDays: Int? { upcomingSoon.first?.daysLeft }

    /// 每课新内容总数
    var newTotal: Int { newFiles.values.reduce(0) { $0 + $1.count } }

    func ddlText(for e: UpcomingEvent) -> String {
        let d = e.daysLeft ?? 0
        let tag = d == 0 ? "今天" : "\(d)天后"
        var ctag = courses.first { String($0.id) == e.context }?.name ?? ""
        if ctag.count > 14 { ctag = String(ctag.prefix(13)) + "…" }
        var t = e.title
        if t.count > 22 { t = String(t.prefix(20)) + "…" }
        let prefix = ctag.isEmpty ? "" : "\(ctag)："
        let mark = isManualDdl(e) ? "✍️ " : ""
        return "\(mark)\(e.dueText) · \(prefix)\(t)（\(tag)）"
    }

    // MARK: 用户操作（DDL 已提交 / 新内容已读 / 同步勾选 / 过滤开关）

    func markDdlDone(_ e: UpcomingEvent) {
        if !ddlDone.contains(e.id) { ddlDone.append(e.id) }
        log("DDL 已标记提交: \(e.title)")
        saveState()
    }

    func restoreDdlDone() {
        ddlDone = []
        saveState()
    }

    func clearNew(_ id: Int64) {
        guard newFiles[id] != nil else { return }
        newFiles[id] = nil
        saveState()
    }

    func clearAllNew() {
        newFiles = [:]
        saveState()
    }

    // MARK: 课程文件菜单（悬停展开 → 直接打开文件）

    struct MenuFile: Identifiable, Hashable {
        let fid: String
        let name: String
        let path: String
        var id: String { fid }
    }

    func isNewFile(_ courseId: Int64, _ name: String) -> Bool {
        newFiles[courseId]?.contains(name) ?? false
    }

    /// 课程子菜单：外部链接（如 Google Drive 课件夹）
    func linksFor(_ courseId: Int64) -> [ExternalLink] { links[String(courseId)] ?? [] }

    /// 课程子菜单数据：manifest 文件列表（自然排序）
    func menuFiles(for courseId: Int64) -> [MenuFile] {
        (manifest[String(courseId)] ?? [:]).map { fid, f in
            MenuFile(fid: fid,
                     name: f.name.isEmpty ? (f.path as NSString).lastPathComponent : f.name,
                     path: f.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func readManifest() -> Manifest {
        guard let data = try? Data(contentsOf: supportDir.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return m
    }

    static func writeManifest(_ m: Manifest) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: supportDir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    /// 重新读取 manifest（启动 / 同步完成后调用）
    func reloadManifest() {
        manifest = Self.readManifest()
    }

    /// 重新读取外部链接表（启动 / 同步完成后调用）
    func reloadLinks() {
        links = SyncEngine.shared.loadLinksMap()
    }

    /// 课程子菜单数据（优先磁盘实时结构 → 目录树；尚未扫描到则回退 manifest 平铺）
    func menuNodes(for c: CachedCourse) -> [MenuNode] {
        if let entries = libTree[c.id] {
            return Self.buildTree(entries)
        }
        return menuFiles(for: c.id).map {
            MenuNode(id: "f:" + $0.fid, name: $0.name, path: $0.path, fid: $0.fid, children: [])
        }
    }

    /// 平铺清单 → 目录树（目录优先、自然排序）
    static func buildTree(_ entries: [LibEntry]) -> [MenuNode] {
        final class Dir {
            var files: [(name: String, path: String)] = []
            var subs: [String: Dir] = [:]
        }
        let root = Dir()
        for e in entries {
            var cur = root
            for d in e.dirs {
                if let n = cur.subs[d] { cur = n } else { let n = Dir(); cur.subs[d] = n; cur = n }
            }
            cur.files.append((e.name, e.path))
        }
        func build(_ d: Dir, _ prefix: [String]) -> [MenuNode] {
            var dirsOut: [MenuNode] = []
            for (name, sub) in d.subs {
                let p = prefix + [name]
                dirsOut.append(MenuNode(id: "d:" + p.joined(separator: "/"), name: name, path: nil,
                                        fid: nil, children: build(sub, p)))
            }
            dirsOut.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var filesOut: [MenuNode] = d.files.map {
                MenuNode(id: "f:" + (prefix + [$0.name]).joined(separator: "/"),
                         name: $0.name, path: $0.path, fid: nil, children: [])
            }
            filesOut.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return dirsOut + filesOut
        }
        return build(root, [])
    }

    /// 扫描课程文件夹（同步版本；调用方负责放到后台线程）
    nonisolated static func scanTree(_ root: URL) -> [LibEntry] {
        var out: [LibEntry] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return out }
        let rootPath = root.standardizedFileURL.path
        var seen = 0
        for case let u as URL in en {
            seen += 1
            if seen > 30000 || out.count >= 4000 { break }
            guard let rv = try? u.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            if u.lastPathComponent == ".DS_Store" { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(rootPath + "/") else { continue }
            let comps = String(p.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
            guard let name = comps.last, comps.count <= 12 else { continue }
            out.append(LibEntry(dirs: Array(comps.dropLast()), name: name, path: p))
        }
        return out
    }

    /// 扫描课程文件夹（带超时；成功返回条目，超时返回 nil 走 manifest 回退）
    func scanTreeAsync(_ root: URL, timeout: Double = 8) async -> [LibEntry]? {
        let box = Box<[LibEntry]>()
        DispatchQueue.global(qos: .utility).async {
            box.value = Self.scanTree(root)
            box.done = true
        }
        let steps = Int(timeout / 0.4)
        for _ in 0..<steps {
            if box.done { return box.value ?? [] }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    /// 刷新课程文件夹实时结构（菜单打开 / 同步完成后调用；1.5 秒防抖）
    func refreshLibrary(force: Bool = false) async {
        if libRefreshInFlight { return }
        if !force, let last = libLastRefresh, Date().timeIntervalSince(last) < 1.5 { return }
        libRefreshInFlight = true
        libLastRefresh = Date()
        defer { libRefreshInFlight = false }
        let snapshot = courses.map { ($0.id, $0.url) }
        var total = 0
        for (id, url) in snapshot {
            if let entries = await scanTreeAsync(url) {
                libTree[id] = entries
                total += entries.count
            }
        }
        log("文件树刷新: \(snapshot.count) 门课 / \(total) 个文件")
    }

    /// 菜单点击文件/目录节点；路径失效（用户移动过）时按文件名在课程目录内自愈找回
    func openNode(_ course: CachedCourse, _ n: MenuNode) {
        let name = n.name.isEmpty ? ((n.path ?? "") as NSString).lastPathComponent : n.name
        guard !name.isEmpty else { return }
        if let p = n.path, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            log("菜单打开文件: \(name)")
            clearNew(course.id)
            return
        }
        Task { @MainActor in
            if let p = await healedPath(for: course, n) {
                log("菜单打开（路径自愈）: \(name) → \(p)")
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
                clearNew(course.id)
            } else {
                log("菜单打开失败（未找到）: \(name) @ \(course.url.path)")
                let a = NSAlert()
                a.messageText = "找不到「\(name)」"
                a.informativeText = "文件可能已被改名或删除。已为你打开课程文件夹。"
                a.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                _ = a.runModal()
                NSWorkspace.shared.open(course.url)
            }
        }
    }

    /// 「在 Finder 中显示」：定位文件/目录（失效时同样按文件名自愈）；找不到则提示并打开课程文件夹
    func revealNode(_ course: CachedCourse, _ n: MenuNode) {
        let name = n.name.isEmpty ? ((n.path ?? "") as NSString).lastPathComponent : n.name
        guard !name.isEmpty else { return }
        if let p = n.path, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            log("菜单在 Finder 显示: \(name)")
            return
        }
        Task { @MainActor in
            if let p = await healedPath(for: course, n) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                log("菜单在 Finder 显示（路径自愈）: \(name) → \(p)")
            } else {
                log("菜单定位失败（未找到）: \(name) @ \(course.url.path)")
                let a = NSAlert()
                a.messageText = "找不到「\(name)」"
                a.informativeText = "文件可能已被改名或删除。已为你打开课程文件夹。"
                a.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                _ = a.runModal()
                NSWorkspace.shared.open(course.url)
            }
        }
    }

    /// 节点 → 有效路径：原路径失效时按文件名在课程目录内找回（文件会顺带修 manifest）
    func healedPath(for course: CachedCourse, _ n: MenuNode) async -> String? {
        let name = n.name.isEmpty ? ((n.path ?? "") as NSString).lastPathComponent : n.name
        guard !name.isEmpty else { return nil }
        if let p = n.path, FileManager.default.fileExists(atPath: p) { return p }
        let dir = course.url
        let found: String? = await Task.detached(priority: .userInitiated) {
            Self.findByName(in: dir, name)
        }.value
        guard let p = found else { return nil }
        if !n.isDir {
            let cid = String(course.id)
            let fid = n.fid
            if var cm = manifest[cid] {
                let key = fid ?? cm.first(where: { $0.value.name == name })?.key
                if let key, var e = cm[key] {
                    e.path = p
                    cm[key] = e
                    manifest[cid] = cm
                    Self.writeManifest(manifest)
                }
            }
        }
        return p
    }

    nonisolated static func findByName(in root: URL, _ name: String) -> String? {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for case let u as URL in en where u.lastPathComponent == name {
            return u.path
        }
        return nil
    }

    func setSyncEnabled(_ id: Int64, _ on: Bool) {
        if on { syncDisabled.remove(id) } else { syncDisabled.insert(id) }
        saveState()
    }

    func setSkipVideos(_ v: Bool) { skipVideos = v; saveState() }
    func setSkipBig(_ v: Bool) { skipBig = v; saveState() }

    // MARK: 手动 DDL

    /// 宽松解析：ISO8601 或 "yyyy-MM-dd HH:mm" / "yyyy-MM-dd"（本地时区）
    static func normalizedISO(_ s: String) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return iso.string(from: d) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return iso.string(from: d) }
        }
        return nil
    }

    func addManualDdl(title: String, courseId: Int64, date: Date) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        addManualDdl(title: title, courseId: courseId, dueISO: f.string(from: date))
    }

    func addManualDdl(title: String, courseId: Int64, dueISO raw: String) {
        let due = Self.normalizedISO(raw) ?? raw
        if !manualDdl.contains(where: { $0.title == title && $0.courseId == courseId && $0.due == due }) {
            manualDdl.append(ManualDdl(title: title, courseId: courseId, due: due))
        }
        log("手动 DDL 添加: \(title) [课程 \(courseId)] due=\(due)")
        saveState()
    }

    func removeManualDdl(_ e: UpcomingEvent) {
        guard let eid = e.evid, eid.hasPrefix("manual-") else { return }
        let uid = String(eid.dropFirst("manual-".count))
        manualDdl.removeAll { $0.uid == uid }
        ddlDone.removeAll { $0 == e.id }
        log("手动 DDL 删除: \(e.title)")
        saveState()
    }

    /// 自动化钩子：同步库里的 .add-ddl（JSON 对象或数组）→ 添加手动 DDL，用完即删
    /// 例：{"title":"Essay 初稿","courseId":6306,"due":"2026-11-01T23:59:00+08:00"}
    func consumeAddDdlHook() {
        let marker = syncRoot.appendingPathComponent(".add-ddl")
        guard let data = try? Data(contentsOf: marker) else { return }
        try? FileManager.default.removeItem(at: marker)
        var items: [[String: Any]] = []
        if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            items = [one]
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = arr
        }
        var n = 0
        for it in items {
            guard let title = (it["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty, let due = it["due"] as? String, !due.isEmpty else { continue }
            var cid: Int64 = 0
            if let v = it["courseId"] as? NSNumber { cid = v.int64Value }
            else if let v = it["courseId"] as? String { cid = Int64(v) ?? 0 }
            addManualDdl(title: title, courseId: cid, dueISO: due)
            n += 1
        }
        log("检测到 .add-ddl：添加 \(n) 条手动 DDL")
    }

    func loadCache() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: supportDir.appendingPathComponent("courses.json")),
           let list = try? JSONDecoder().decode([CachedCourse].self, from: data) {
            courses = list
        }
        if let data = try? Data(contentsOf: supportDir.appendingPathComponent("state.json")),
           let st = try? JSONDecoder().decode(SyncState.self, from: data) {
            lastSync = st.lastSync
            upcoming = st.upcoming ?? []
            if let v = st.skipVideos { skipVideos = v }
            if let v = st.skipBig { skipBig = v }
            ddlDone = st.ddlDone ?? []
            var nf: [Int64: [String]] = [:]
            for (k, v) in st.newFiles ?? [:] {
                if let kid = Int64(k) { nf[kid] = v }
            }
            newFiles = nf
            syncDisabled = Set(st.syncDisabled ?? [])
            manualDdl = st.manual ?? []
        }
    }

    func saveCourses() {
        if let data = try? JSONEncoder().encode(courses) {
            try? data.write(to: supportDir.appendingPathComponent("courses.json"), options: .atomic)
        }
    }

    func saveState() {
        let st = SyncState(
            lastSync: lastSync,
            upcoming: upcoming,
            skipVideos: skipVideos,
            skipBig: skipBig,
            ddlDone: ddlDone,
            newFiles: Dictionary(uniqueKeysWithValues: newFiles.map { (String($0.key), $0.value) }),
            syncDisabled: Array(syncDisabled).sorted(),
            manual: manualDdl)
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: supportDir.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}

// MARK: - 同步引擎

@MainActor
final class SyncEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = SyncEngine()
    var state: AppState { AppState.shared }

    var webView: WKWebView?
    var hiddenWindow: NSWindow?
    var loginWV: WKWebView?
    var loginWindow: NSWindow?
    var lastLoginURLSeen: String?
    var loginCookieSig: String?
    var loginVerifyBusy = false
    var loginVerifyAt: Date?
    var loginFinished = false
    var lastNavError: String?
    var lastNavErrorAt: Date?

    // base64 分片回退下载用
    var chunks: [Int64: [Int: String]] = [:]
    var pending: [Int64: CheckedContinuation<Data, Error>] = [:]

    enum SyncError: LocalizedError {
        case needLogin, noWebView, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .needLogin: return "Canvas 会话失效，需要重新登录"
            case .noWebView: return "WebView 未就绪"
            case .badResponse(let s): return "Canvas 响应异常：\(s)"
            }
        }
    }

    // MARK: WebView 基建

    func ensureWebView() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.add(self, name: "sync")
        let helper = """
        window.fetchAllPages = async function(path) {
            let out = [], url = path;
            while (url) {
                const r = await fetch(url, {credentials: 'include', headers: {'Accept': 'application/json'}});
                if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + path);
                const j = await r.json();
                if (Array.isArray(j)) out = out.concat(j);
                const link = r.headers.get('Link') || '';
                const m = link.match(/<([^>]+)>;\\s*rel="next"/);
                url = m ? m[1] : null;
                if (!m && !Array.isArray(j)) break;
            }
            return out;
        };
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: helper, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        wv.navigationDelegate = self
        webView = wv
        // 挂到离屏窗口，避免后台节流
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        win.contentView = cv
        cv.addSubview(wv)
        hiddenWindow = win
        log("隐藏 WebView 已创建")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === loginWV {
            log("登录窗 page didFinish: \(webView.url?.absoluteString.prefix(120) ?? "nil")")
            Task { @MainActor in self.tryFinishLogin() }
            checkSamlSubmitPage(on: webView)
            checkKmsi(on: webView)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === loginWV {
            log("登录窗 开始加载: \(webView.url?.absoluteString.prefix(110) ?? "nil")")
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if webView === loginWV {
            log("登录窗 重定向: \(webView.url?.absoluteString.prefix(110) ?? "nil")")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavError(error)
        log("导航失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavError(error)
        if webView === loginWV {
            log("登录窗 加载失败: \(error.localizedDescription)")
        }
    }

    /// 记录导航错误（忽略 -999 cancelled：SAML POST 回流/重定向中常见，不算真错误）
    func recordNavError(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        lastNavError = "\(ns.code) \(ns.localizedDescription)"
        lastNavErrorAt = Date()
    }

    /// 导航策略：登录窗只允许 http(s)/about/data 留在窗内，其他协议一律拦下（防被系统交给外部应用/浏览器）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = (url?.scheme ?? "").lowercased()
        let ok = scheme.isEmpty || scheme == "about" || scheme == "data" || scheme == "http" || scheme == "https"
        guard webView === loginWV else {
            decisionHandler(ok ? .allow : .cancel)
            return
        }
        if ok {
            if navigationAction.targetFrame == nil {
                log("登录窗 新窗口请求: \(url?.absoluteString.prefix(100) ?? "nil")")
            }
            decisionHandler(.allow)
        } else {
            log("登录窗 拦截外部协议跳转: \(url?.absoluteString.prefix(100) ?? "nil")")
            decisionHandler(.cancel)
        }
    }

    /// SSO 页面若用 window.open / target=_blank（ADFS 回流常见），转为本窗口继续，避免丢失或外跳
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url,
           let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            log("登录窗 新窗口请求 → 转为当前窗口继续: \(u.absoluteString.prefix(100))")
            loginWV?.load(URLRequest(url: u))
        }
        return nil
    }

    /// 登录窗被手动关闭：清掉引用，让下次「登录」重新开窗
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === loginWindow else { return }
        if !loginFinished { log("登录窗口已关闭") }
        loginWindow = nil
        loginWV = nil
        loginFinished = false
    }

    /// 在指定 WebView 内执行异步 JS（返回字符串结果）
    func callJS(_ body: String, on wv: WKWebView) async throws -> String {
        let result = try await wv.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        if let s = result as? String { return s }
        if result == nil || result is NSNull { return "null" }
        return String(describing: result!)
    }

    @discardableResult
    func eval(_ body: String) async throws -> String {
        guard let wv = webView else { throw SyncError.noWebView }
        return try await callJS(body, on: wv)
    }

    // MARK: 会话检查 / 登录

    let selfCheckBody = """
    try {
        const r = await fetch('/api/v1/users/self', {credentials: 'include'});
        return JSON.stringify({ok: r.ok, status: r.status, host: location.host});
    } catch (e) { return JSON.stringify({ok: false, error: String(e), host: location.host}); }
    """

    func fetchSelfOK(_ wv: WKWebView) async -> Bool {
        guard isCanvasURL(wv.url) else {
            log("fetchSelf: 非 canvas 域 (\(wv.url?.absoluteString.prefix(100) ?? "nil"))")
            return false
        }
        do {
            let raw = try await callJS(selfCheckBody, on: wv)
            let data = Data(raw.utf8)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool else {
                log("self 响应解析失败: \(raw.prefix(160))")
                return false
            }
            if !ok { log("self 检查未通过: \(raw.prefix(160))") }
            return ok
        } catch {
            log("self 检查异常: \(error.localizedDescription)")
            return false
        }
    }

    /// 会话检查：快路直接验；疑过期则重载并等 SSO 静默重登（ADFS 持久 cookie 尚在时自动回流，无需用户）
    func checkSession(force: Bool = false) async throws -> Bool {
        ensureWebView()
        guard let wv = webView else { throw SyncError.noWebView }

        // 快路：已停在 canvas 域且页面稳定 → 直接验证（不重载，秒出结果）
        if isCanvasURL(wv.url), !wv.isLoading {
            if await fetchSelfOK(wv) { log("会话检查: OK（快路）"); return true }
            log("会话检查：快路未通过，尝试静默重登…")
        }

        // 慢路：重载首页。session 过期会 302 去 SSO；ADFS cookie 尚在时自动回流，全程无需用户
        lastNavError = nil
        lastNavErrorAt = nil
        log("会话检查：重载 \(Cfg.origin)（force=\(force)）")
        wv.load(URLRequest(url: URL(string: Cfg.origin)!))
        try? await Task.sleep(nanoseconds: 700_000_000)   // 等导航链启动（避开 isLoading 竞态）

        let deadline = Date().addingTimeInterval(45)
        var needUser = false
        var canvasFail = 0
        while Date() < deadline {
            if wv.isLoading {
                // 导航链进行中 → 等
            } else if isCanvasURL(wv.url) {
                if await fetchSelfOK(wv) { log("会话检查: OK（静默验证通过）"); return true }
                canvasFail += 1
                if (wv.url?.path.lowercased().contains("/login") ?? false) || canvasFail >= 6 {
                    needUser = true
                    break
                }
            } else if await isLoginPageNeedingUser(wv) {
                needUser = true
                break
            } else if let e = lastNavError, let t = lastNavErrorAt, Date().timeIntervalSince(t) < 3 {
                log("会话检查：导航错误（\(e)）")
                break
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        log("会话检查: FAIL（needUser=\(needUser) url=\(wv.url?.absoluteString.prefix(120) ?? "nil")）")
        return false
    }

    /// 探测当前页是否是「等人输入」的登录页（含密码框）→ 静默重登流程可提前放弃、改弹登录窗
    func isLoginPageNeedingUser(_ wv: WKWebView) async -> Bool {
        let probe = """
        (function(){
            try { return document.querySelector('input[type=password]') ? 'YES' : 'NO'; }
            catch (e) { return 'NO'; }
        })()
        """
        return ((try? await callJS(probe, on: wv)) == "YES")
    }

    func showLogin() {
        if let w = loginWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "登录 Canvas · \(Cfg.host)（登录后自动关闭）"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let content = win.contentView ?? NSView(frame: .zero)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true   // SSO 流程可能用 window.open
        let wv = WKWebView(frame: content.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: URL(string: Cfg.origin + "/login")!))
        content.addSubview(wv)
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        loginWV = wv
        loginWindow = win
        lastLoginURLSeen = nil
        loginFinished = false
        loginVerifyAt = nil
        loginCookieSig = nil
        snapshotLoginCookies()
        log("登录窗口已打开")

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.loginWindow != nil else { t.invalidate(); return }
                self.tryFinishLogin()
            }
        }
    }

    // MARK: 登录成功判定（多通道，任何一路成功即收窗 + 自动同步）

    func tryFinishLogin() {
        guard let wv = loginWV, loginWindow != nil else { return }
        let u = wv.url?.absoluteString ?? "nil"
        if u != lastLoginURLSeen {
            lastLoginURLSeen = u
            log("登录窗 URL: \(u.prefix(120))")
        }
        // 通道①：已回到 canvas 域 → 直接验会话
        if isCanvasURL(wv.url), !wv.isLoading {
            Task { @MainActor in
                if await self.fetchSelfOK(wv) { self.finishLoginSuccess() }
            }
        }
        // 通道②：站点 Cookie 发生变化（ADFS 通过但回流卡住等情况）→ 静默验证
        checkLoginCookieChange()
    }

    /// 取当前与 Canvas 相关域名的 Cookie 指纹（名称+值排序拼接；域名后缀匹配 .polyu.edu.hk 等）
    nonisolated static func cookieSignature(_ cookies: [HTTPCookie]) -> String {
        let host = Cfg.host.lowercased()
        return cookies
            .filter { c in
                var d = c.domain.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                return !d.isEmpty && host.hasSuffix(d)
            }
            .map { "\($0.name)=\($0.value)" }
            .sorted()
            .joined(separator: ";")
    }

    func snapshotLoginCookies() {
        guard let wv = loginWV else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let sig = Self.cookieSignature(cookies)
            Task { @MainActor in SyncEngine.shared.loginCookieSig = sig }
        }
    }

    func checkLoginCookieChange() {
        guard let wv = loginWV, loginWindow != nil, !loginVerifyBusy else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let sig = Self.cookieSignature(cookies)
            Task { @MainActor in
                let self_ = SyncEngine.shared
                guard self_.loginWindow != nil else { return }
                if let base = self_.loginCookieSig, base != sig {
                    self_.loginCookieSig = sig
                    await self_.verifyLoginSilently()
                } else if self_.loginCookieSig == nil {
                    self_.loginCookieSig = sig
                }
            }
        }
    }

    /// 用隐藏 WebView 静默验证会话（不打扰登录窗；带冷却）
    func verifyLoginSilently() async {
        guard loginWindow != nil, !loginVerifyBusy, !state.isSyncing, !loginFinished else { return }
        if let t = loginVerifyAt, Date().timeIntervalSince(t) < 8 { return }
        loginVerifyBusy = true
        loginVerifyAt = Date()
        defer { loginVerifyBusy = false }
        log("登录窗：Cookie 变化，静默验证会话…")
        let ok = (try? await checkSession(force: true)) == true
        if ok {
            finishLoginSuccess()
        } else {
            log("登录窗：会话尚无效，继续等待")
        }
    }

    /// 心跳保活（每 30 分钟）：轻量请求续期 Canvas 会话；失效时先试静默重登；彻底失败不弹窗
    func keepAlive() async {
        guard !state.isSyncing, loginWindow == nil else { return }
        ensureWebView()
        guard let wv = webView else { return }
        if isCanvasURL(wv.url), !wv.isLoading, await fetchSelfOK(wv) {
            log("心跳: OK")
            return
        }
        log("心跳: 会话可能已过期，尝试静默重登…")
        let ok = (try? await checkSession(force: true)) == true
        log("心跳: 静默重登\(ok ? "成功" : "失败（保持现状，下次同步时再试）")")
    }

    /// ADFS/SAML 递交页等待：若 3.5 秒未自动跳转，则协助递交一次（防卡在半路）
    func checkSamlSubmitPage(on wv: WKWebView) {
        let probe = """
        (function(){
            try {
                const fs = Array.from(document.forms || []);
                const f = fs.find(x => (x.querySelector && x.querySelector('input[name="SAMLResponse"]')) ||
                                       /saml|canvas/i.test(x.getAttribute('action') || ''));
                return f ? 'YES' : 'NO';
            } catch (e) { return 'NO'; }
        })()
        """
        Task { @MainActor in
            guard self.loginWV === wv, self.loginWindow != nil else { return }
            guard let r = try? await self.callJS(probe, on: wv), r == "YES" else { return }
            let u0 = wv.url?.absoluteString
            log("登录窗：检测到 SAML 递交页，等待自动跳转…")
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard self.loginWV === wv, self.loginWindow != nil,
                  wv.url?.absoluteString == u0, !wv.isLoading else { return }
            let submit = """
            (function(){
                try {
                    const fs = Array.from(document.forms || []);
                    const f = fs.find(x => (x.querySelector && x.querySelector('input[name="SAMLResponse"]')) ||
                                           /saml|canvas/i.test(x.getAttribute('action') || ''));
                    if (f) { f.submit(); return 'SUBMITTED'; }
                    return 'GONE';
                } catch (e) { return 'ERR'; }
            })()
            """
            if let r2 = try? await self.callJS(submit, on: wv), r2 == "SUBMITTED" {
                log("登录窗：SAML 递交页 3.5 秒未跳转，已协助提交")
            }
        }
    }

    /// 登录页若提供「保持登录 / Remember me」（KMSI）复选框 → 自动勾选，让 SSO 会话尽量持久
    func checkKmsi(on wv: WKWebView) {
        let js = """
        (function(){
            try {
                const cbs = Array.from(document.querySelectorAll('input[type=checkbox]'));
                const hit = cbs.find(c => /kmsi|keep.*(sign|log)|remember|stay.*sign|保持|记住/i.test(
                    (c.name||'') + ' ' + (c.id||'') + ' ' + (c.getAttribute('aria-label')||'')));
                if (!hit) return 'NONE';
                if (hit.checked) return 'ALREADY';
                hit.checked = true;
                hit.dispatchEvent(new Event('change', {bubbles: true}));
                return 'CHECKED';
            } catch (e) { return 'ERR'; }
        })()
        """
        Task { @MainActor in
            guard self.loginWV === wv else { return }
            if let r = try? await self.callJS(js, on: wv), r == "CHECKED" {
                log("登录窗：检测到「保持登录」，已自动勾选")
            }
        }
    }

    func finishLoginSuccess() {
        guard !loginFinished, loginWindow != nil else { return }
        loginFinished = true
        log("登录成功")
        loginWindow?.orderOut(nil)
        loginWindow?.close()
        loginWindow = nil
        loginWV = nil
        state.progress = "✅ 登录成功，开始同步…"
        Task { @MainActor in await self.syncAll() }
    }

    // MARK: 同步主流程

    func syncAll(only: Set<Int64>? = nil) async {
        guard !state.isSyncing else { log("已有同步进行中，跳过"); return }
        state.isSyncing = true
        defer {
            state.isSyncing = false
            state.saveState()
        }
        log("=== 同步开始 ===\(only == nil ? "" : " 仅课程 \(only!.map(String.init).joined(separator: ","))") 库=\(syncRoot.path)")
        do {
            state.progress = "检查 Canvas 会话…"
            guard try await checkSession(force: true) else {
                state.progress = "⚠️ 未登录：菜单 →「登录 Canvas…」"
                showLogin()
                return
            }

            // DDL（仅全量同步时刷新）
            if only == nil {
                state.progress = "获取 DDL…"
                if let ups = try? await fetchUpcoming() {
                    state.upcoming = ups
                    log("DDL 获取 \(ups.count) 条（未提交/未忽略 \(state.upcomingSoon.count) 条）")
                }
            }

            state.progress = "获取课程列表…"
            let remote = try await fetchCourses()
            log("课程数 \(remote.count)")
            guard !remote.isEmpty else {
                state.progress = "⚠️ 未取到课程"
                return
            }

            // 合并：Canvas 远端 ∪ 本地缓存（保留已结束课程的入口）
            // 文件夹名 = 显示名自动生成（不再映射本机旧目录，跨机器可复现）
            var merged: [CachedCourse] = []
            var usedFolders = Set<String>()
            func uniqueFolder(_ display: String) -> String {
                var f = courseFolderName(display)
                var n = 2
                while usedFolders.contains(f) {
                    f = courseFolderName(display) + " \(n)"
                    n += 1
                }
                usedFolders.insert(f)
                return f
            }
            for (id, name) in remote {
                let display = displayOverrides[id] ?? shortName(name)
                merged.append(CachedCourse(id: id, name: display, folder: uniqueFolder(display)))
            }
            for old in state.courses where !merged.contains(where: { $0.id == old.id }) {
                merged.append(CachedCourse(id: old.id, name: old.name, folder: uniqueFolder(old.name)))
            }
            state.courses = merged
            state.saveCourses()

            // 建目录：~/Documents/Canvas 同步/<课程>/
            for c in merged {
                try? FileManager.default.createDirectory(at: c.url, withIntermediateDirectories: true)
            }

            // 逐课程同步（只同步 Canvas 远端课程）
            // manifest 迁移：同步库以外的旧记录（如历史目录）作废，保证「库 = 自足快照」
            var manifest: Manifest = [:]
            let rootPrefix = syncRoot.path + "/"
            for (k, cm) in loadManifest() {
                manifest[k] = cm.filter { $0.value.path.hasPrefix(rootPrefix) }
            }
            var added = 0, failed = 0, kept = 0
            var nSkipVideo = 0, nSkipBig = 0, nSkipCourse = 0, nManifest = 0
            var linksMap: LinkMap = loadLinksMap()

            for (id, name) in remote {
                guard let course = merged.first(where: { $0.id == id }) else { continue }
                if let only, !only.contains(id) { continue }
                if state.syncDisabled.contains(id) {
                    nSkipCourse += 1
                    log("课程 \(id) \(name): 未勾选，本轮跳过")
                    continue
                }
                state.progress = "同步「\(name)」…"
                let fetched: (files: [RemoteFile], links: [ExternalLink])? =
                    try? await fetchCourseFiles(courseId: id)
                let files = fetched?.files ?? []
                if let ls = fetched?.links { linksMap[String(id)] = ls }
                log("课程 \(id) \(name): 共 \(files.count) 个文件条目，外部链接 \(fetched?.links.count ?? 0) 条")
                var cm = manifest[String(id)] ?? [:]
                // 源已成功取到：清理不再出现在源里的记录（菜单保持「源现状」；磁盘文件不动）
                if let s = fetched {
                    let srcFids = Set(s.files.map { String($0.id) })
                    let stale = cm.keys.filter { !srcFids.contains($0) }
                    if !stale.isEmpty {
                        log("  记录清理: 移除 \(stale.count) 条不再同步的条目")
                        for k in stale { cm.removeValue(forKey: k) }
                    }
                }
                let syncDir = course.url
                try? FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)

                // 全课程目录索引（含用户整理过的子文件夹），用于去重（后台+超时）
                var index: [String: [(size: Int64, path: String)]] = [:]
                if let idx = await scanCourseDirAsync(course.url) {
                    index = idx
                    log("  目录索引: \(idx.count) 个文件名")
                } else {
                    log("  ⚠️ 目录扫描超时/被拒（TCC？），降级为只扫课程文件夹")
                    if let names = await shallowListAsync(syncDir) {
                        for n in names {
                            index[n] = [(0, syncDir.appendingPathComponent(n).path)]
                        }
                    } else {
                        log("  ⚠️ 降级扫描也超时，本轮仅靠 manifest 去重")
                    }
                }
                var consumed = Set<String>()

                var courseNew: [String] = []
                for f in files {
                    let key = String(f.id)
                    // 1) manifest 命中且文件仍在 → 跳过
                    //    例外：.webloc 记录（曾被过滤跳过）且当前过滤已关闭 → 清记录、走真实下载
                    if let m = cm[key], FileManager.default.fileExists(atPath: m.path) {
                        if m.name.hasSuffix(".webloc") && skipKind(name: f.name ?? m.name, size: m.size) == nil {
                            cm.removeValue(forKey: key)
                        } else {
                            consumed.insert(m.path)
                            nManifest += 1
                            continue
                        }
                    }
                    var fileName = f.name ?? ""
                    if fileName.contains("%"), let decoded = fileName.removingPercentEncoding {
                        fileName = decoded
                    }
                    var link: String? = nil
                    var sizeHint: Int64 = 0   // 精确大小在 public_url 解析阶段拿到

                    // 2) 名字已知 → 查全目录索引（用户已整理到别处）
                    if !fileName.isEmpty,
                       let hit = pickFromIndex(index, name: fileName, consumed: consumed) {
                        cm[key] = ManFile(name: fileName, size: hit.size, path: hit.path)
                        consumed.insert(hit.path)
                        kept += 1
                        continue
                    }

                    // 3) 名字未知（公告/页面引用）→ 先解析文件名再查
                    if fileName.isEmpty {
                        let pu = await resolvePublicURL(fileId: f.id)
                        if let l = pu.link, let n = pu.name ?? nameFromURL(l) {
                            fileName = n
                            link = l
                            if let s = pu.size { sizeHint = max(sizeHint, s) }
                            if let hit = pickFromIndex(index, name: fileName, consumed: consumed) {
                                cm[key] = ManFile(name: fileName, size: hit.size, path: hit.path)
                                consumed.insert(hit.path)
                                kept += 1
                                continue
                            }
                        }
                    }

                    // 4) 过滤：跳过视频 / 超大文件（写 .webloc 在线链接，并记入 manifest 供菜单列出 / 去重）
                    if let kind = skipKind(name: fileName, size: sizeHint) {
                        switch kind {
                        case .video: nSkipVideo += 1
                        case .big: nSkipBig += 1
                        }
                        let wName = weblocPath(name: fileName, fileId: f.id, dir: syncDir).lastPathComponent
                        if let hit = pickFromIndex(index, name: wName, consumed: consumed) {
                            cm[key] = ManFile(name: wName, size: hit.size, path: hit.path)
                            consumed.insert(hit.path)
                        } else {
                            let wp = writeWebloc(name: fileName, fileId: f.id, courseId: id, dir: syncDir)
                            cm[key] = ManFile(name: wp.lastPathComponent, size: sizeHint, path: wp.path)
                            index[wp.lastPathComponent, default: []].append((sizeHint, wp.path))
                            consumed.insert(wp.path)
                        }
                        log("  跳过(\(kind == .video ? "视频" : "大文件")) fid=\(f.id) \(fileName)")
                        continue
                    }

                    // 5) 下载
                    do {
                        let dest = try await download(fileId: f.id, name: fileName, link: link,
                                                      sizeHint: sizeHint, to: syncDir)
                        let actual = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber
                        cm[key] = ManFile(name: dest.lastPathComponent,
                                          size: actual?.int64Value ?? 0, path: dest.path)
                        index[dest.lastPathComponent, default: []].append((actual?.int64Value ?? 0, dest.path))
                        consumed.insert(dest.path)
                        added += 1
                        courseNew.append(dest.lastPathComponent)
                    } catch let sk as SkippedFile {
                        // 兜底过滤（名字/大小只有解析 public_url 后才拿到）
                        switch sk.kind {
                        case .video: nSkipVideo += 1
                        case .big: nSkipBig += 1
                        }
                        let wp = writeWebloc(name: sk.name, fileId: f.id, courseId: id, dir: syncDir)
                        cm[key] = ManFile(name: wp.lastPathComponent, size: sk.size, path: wp.path)
                        index[wp.lastPathComponent, default: []].append((sk.size, wp.path))
                        consumed.insert(wp.path)
                        log("  跳过(\(sk.kind == .video ? "视频" : "大文件")) fid=\(f.id) \(sk.name)")
                    } catch {
                        failed += 1
                        log("下载失败 fid=\(f.id) \(fileName): \(error.localizedDescription)")
                    }
                }
                if !courseNew.isEmpty {
                    var arr = state.newFiles[id] ?? []
                    arr.append(contentsOf: courseNew)
                    if arr.count > 50 { arr = Array(arr.suffix(50)) }
                    state.newFiles[id] = arr
                }
                manifest[String(id)] = cm
                saveManifest(manifest)
            }

            saveLinksMap(linksMap)
            state.reloadManifest()
            state.reloadLinks()
            await state.refreshLibrary(force: true)
            state.lastSync = Date()
            var parts = ["新增 \(added)", "已在库 \(kept + nManifest)"]
            if nSkipVideo + nSkipBig > 0 { parts.append("跳过 \(nSkipVideo + nSkipBig)") }
            if nSkipCourse > 0 { parts.append("未勾选 \(nSkipCourse) 门") }
            let summary = parts.joined(separator: "，")
            state.progress = failed == 0
                ? "✅ 完成：\(summary)"
                : "⚠️ 完成：\(summary)，失败 \(failed)（见 log.txt）"
            log("=== 同步结束 added=\(added) kept=\(kept) manifest=\(nManifest) skippedVideo=\(nSkipVideo) skippedBig=\(nSkipBig) skippedCourse=\(nSkipCourse) failed=\(failed) ===")
        } catch {
            state.progress = "❌ \(error.localizedDescription)"
            log("同步异常: \(error.localizedDescription)")
        }
    }

    // MARK: 去重辅助

    /// 后台递归扫描课程目录：文件名 → [(大小, 路径)]；超时返回 nil（本轮跳过去重）
    /// 用「后台线程 + 主线程轮询」而不是 taskGroup —— 阻塞型 syscall 卡住协作线程池时超时不可靠
    func scanCourseDirAsync(_ root: URL, timeout: Double = 15) async -> [String: [(size: Int64, path: String)]]? {
        let box = Box<[String: [(size: Int64, path: String)]]>()
        DispatchQueue.global(qos: .utility).async {
            box.value = Self.scanSync(root)
            box.done = true
        }
        let steps = Int(timeout / 0.5)
        for _ in 0..<steps {
            if box.done { return box.value ?? [:] }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// 浅层目录列表（降级用），同样带超时
    func shallowListAsync(_ dir: URL, timeout: Double = 8) async -> [String]? {
        let box = Box<[String]>()
        DispatchQueue.global(qos: .utility).async {
            box.value = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            box.done = true
        }
        let steps = Int(timeout / 0.5)
        for _ in 0..<steps {
            if box.done { return box.value }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    nonisolated static func scanSync(_ root: URL) -> [String: [(size: Int64, path: String)]] {
        var idx: [String: [(size: Int64, path: String)]] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return idx }
        var seen = 0
        for case let u as URL in en {
            seen += 1
            if seen > 20000 { break }  // 保险丝：超大目录不递归到底
            guard let rv = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  rv.isRegularFile == true else { continue }
            if u.lastPathComponent == ".DS_Store" { continue }
            idx[u.lastPathComponent, default: []].append((Int64(rv.fileSize ?? 0), u.path))
        }
        return idx
    }

    /// 从索引里挑一个未被其他 fid 认领的同名文件
    func pickFromIndex(_ index: [String: [(size: Int64, path: String)]],
                       name: String, consumed: Set<String>) -> (size: Int64, path: String)? {
        guard let hits = index[name] else { return nil }
        return hits.first { !consumed.contains($0.path) }
    }

    func nameFromURL(_ link: String) -> String? {
        guard let u = URL(string: link) else { return nil }
        let last = u.lastPathComponent
        let decoded = last.removingPercentEncoding ?? last
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: 过滤（跳过视频 / 超大文件）

    var bigLimit: Int64 { Int64(bigFileLimitMB) * 1024 * 1024 }

    func skipKind(name: String, size: Int64) -> SkipKind? {
        if state.skipVideos, isVideoFile(name) { return .video }
        if state.skipBig, size >= bigLimit { return .big }
        return nil
    }

    /// 被跳过文件的 .webloc 目标路径
    func weblocPath(name: String, fileId: Int64, dir: URL) -> URL {
        let clean = sanitizeName(name.isEmpty ? "file-\(fileId)" : name)
        return dir.appendingPathComponent(clean + ".webloc")
    }

    /// 为被跳过的文件写 .webloc 在线链接（双击用浏览器打开 Canvas 文件页）；返回链接文件路径
    @discardableResult
    func writeWebloc(name: String, fileId: Int64, courseId: Int64, dir: URL) -> URL {
        let dest = weblocPath(name: name, fileId: fileId, dir: dir)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return dest }
        let link = "\(Cfg.origin)/courses/\(courseId)/files/\(fileId)"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>\(link)</string></dict></plist>
        """
        do {
            try xml.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            log("webloc 写入失败 \(dest.lastPathComponent): \(error.localizedDescription)")
        }
        return dest
    }

    // MARK: Canvas API

    struct RemoteCourse: Decodable { let id: Int64; let name: String? }
    struct RemoteFile: Decodable { let id: Int64; let name: String? }
    struct PublicURL: Decodable {
        let public_url: String?
        let url: String?
        let display_name: String?
        let size: Int64?
        var link: String? { public_url ?? url }
    }

    func fetchCourses() async throws -> [(Int64, String)] {
        let body = """
        try {
            const list = await window.fetchAllPages('/api/v1/courses?enrollment_state=active&per_page=100');
            return JSON.stringify(list.filter(c => c.name).map(c => ({id: c.id, name: c.name})));
        } catch (e) { return JSON.stringify({error: String(e), host: location.host}); }
        """
        let raw = try await eval(body)
        let data = Data(raw.utf8)
        if let err = try? JSONDecoder().decode([String: String].self, from: data),
           let msg = err["error"] { throw SyncError.badResponse(msg) }
        let list = try JSONDecoder().decode([RemoteCourse].self, from: data)
        return list.compactMap { c in c.name.map { (c.id, $0) } }
    }

    /// 三源并集：模块文件 ∪ 公告附件 ∪ 页面正文引用（fid 去重，名字尽量取到）
    /// ★ 页面列表接口不含 body，必须逐页取详情（含课程首页 front_page）——有的课材料只在 Pages 里
    /// 顺带收集课程里的外部链接（如 Google Drive 课件夹）→ links.json → 菜单一键打开
    func fetchCourseFiles(courseId: Int64) async throws -> (files: [RemoteFile], links: [ExternalLink]) {
        let body = """
        const map = {};
        const add = (fid, name) => {
            const k = String(fid);
            if (!map[k]) map[k] = name || '';
            else if (!map[k] && name) map[k] = name;
        };
        const counts = {mods: 0, anns: 0, pages: 0, bodies: 0, links: 0};
        const links = [];
        const addLink = (url, title) => {
            if (!url) return;
            url = String(url).trim();
            if (!/^https?:\\/\\//i.test(url)) return;
            try {
                const h = new URL(url).host;
                if (h.includes(location.host) || h.includes('instructure.com')) return;
            } catch (e) { return; }
            if (links.some(l => l.url === url)) return;
            title = String(title || '').replace(/<[^>]+>/g, ' ').replace(/\\s+/g, ' ').trim();
            if (title.length < 3) {
                try {
                    const u = new URL(url);
                    title = u.host.replace(/^www\\./, '') + (u.pathname.length > 1 ? u.pathname.slice(0, 36) : '');
                } catch (e) { title = url.slice(0, 48); }
            }
            if (title.length > 60) title = title.slice(0, 58) + '…';
            links.push({title: title, url: url});
        };
        const scanLinks = (html) => {
            const re = /<a\\b[^>]*href\\s*=\\s*["']([^"']+)["'][^>]*>([\\s\\S]*?)<\\/a>/gi;
            let m;
            while ((m = re.exec(html || ''))) addLink(m[1], m[2]);
        };
        const chunk = async (arr, size, fn) => {
            const out = [];
            for (let i = 0; i < arr.length; i += size) out.push(...await Promise.all(arr.slice(i, i + size).map(fn)));
            return out;
        };
        try {
            const mods = await window.fetchAllPages('/api/v1/courses/\(courseId)/modules?include[]=items&per_page=100');
            counts.mods = mods.length;
            for (const m of mods) {
                for (const it of (m.items || [])) {
                    if (it.type === 'File' && it.content_id) add(it.content_id, it.title);
                    if (it.type === 'ExternalUrl' && it.external_url) addLink(it.external_url, it.title);
                }
            }
        } catch (e) {}
        try {
            const anns = await window.fetchAllPages('/api/v1/courses/\(courseId)/discussion_topics?only_announcements=true&per_page=100');
            counts.anns = anns.length;
            const re = /\\/files\\/(\\d+)/g;
            for (const a of anns) {
                for (const at of (a.attachments || [])) if (at.id) add(at.id, at.display_name || at.filename || '');
                const msg = a.message || '';
                let m; re.lastIndex = 0;
                while ((m = re.exec(msg))) add(m[1], '');
                scanLinks(msg);
            }
        } catch (e) {}
        try {
            const bodies = [];
            const fp = await fetch('/api/v1/courses/\(courseId)/front_page', {credentials: 'include'})
                .then(r => r.ok ? r.json() : null).catch(() => null);
            if (fp && typeof fp.body === 'string') bodies.push(fp.body);
            const pages = await window.fetchAllPages('/api/v1/courses/\(courseId)/pages?per_page=100');
            counts.pages = pages.length;
            const details = await chunk(pages, 8, p =>
                fetch('/api/v1/courses/\(courseId)/pages/' + encodeURIComponent(p.url), {credentials: 'include'})
                    .then(r => r.ok ? r.json() : null).catch(() => null));
            for (const d of details) if (d && typeof d.body === 'string') bodies.push(d.body);
            counts.bodies = bodies.length;
            // 页面正文只同步「作为链接出现」的文件（<a href=".../files/N">）；
            // 纯内嵌图片（<img>/CSS 背景）多为页面装饰素材，忽略
            const re = /<a\\b[^>]*href\\s*=\\s*["'][^"']*\\/files\\/(\\d+)[^"']*["'][^>]*>/gi;
            for (const b of bodies) {
                let m; re.lastIndex = 0;
                while ((m = re.exec(b))) add(m[1], '');
                scanLinks(b);
            }
        } catch (e) {}
        counts.links = links.length;
        return JSON.stringify({files: Object.keys(map).map(k => ({id: Number(k), name: map[k] || null})), links: links.slice(0, 20), counts});
        """
        let raw = try await eval(body)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("三源解析失败 course=\(courseId): \(raw.prefix(120))")
            return ([], [])
        }
        if let counts = obj["counts"] as? [String: Any] {
            log("  源统计: modules=\(counts["mods"] ?? 0) anns=\(counts["anns"] ?? 0) pages=\(counts["pages"] ?? 0) bodies=\(counts["bodies"] ?? 0) links=\(counts["links"] ?? 0)")
        }
        var files: [RemoteFile] = []
        if let arr = obj["files"], let fd = try? JSONSerialization.data(withJSONObject: arr) {
            files = (try? JSONDecoder().decode([RemoteFile].self, from: fd)) ?? []
        }
        var extLinks: [ExternalLink] = []
        if let arr = obj["links"], let ld = try? JSONSerialization.data(withJSONObject: arr) {
            extLinks = (try? JSONDecoder().decode([ExternalLink].self, from: ld)) ?? []
        }
        return (files, extLinks)
    }

    func fetchUpcoming() async throws -> [UpcomingEvent] {
        let body = """
        const out = [];
        let src = 'none';
        try {
            const items = await window.fetchAllPages('/api/v1/planner/items?per_page=100');
            for (const it of items) {
                if (it.plannable_type === 'calendar_event') continue;
                const p = it.plannable || {};
                const due = p.due_at || null;
                if (!due) continue;
                const evid = it.plannable_id ? String(it.plannable_id) : '';
                const sub = Array.isArray(it.submissions) && it.submissions.length ? !!it.submissions[0].submitted : false;
                out.push({title: p.title || p.name || it.plannable_type || '(untitled)', due: due, context: String(it.course_id || ''), evid: evid, url: p.html_url || '', submitted: sub, ptype: it.plannable_type || ''});
            }
            if (out.length) src = 'planner(' + items.length + ')';
        } catch (e) {}
        if (!out.length) {
            try {
                const items = await window.fetchAllPages('/api/v1/users/self/upcoming_events?per_page=50');
                for (const it of items) {
                    const a = it.assignment || {};
                    const due = a.due_at || it.due_at || null;
                    if (!due) continue;
                    out.push({title: it.title || '(untitled)', due: due, context: String((it.context_code || '').replace('course_', '')), evid: a.id ? String(a.id) : '', url: it.html_url || a.html_url || '', submitted: false, ptype: 'assignment'});
                }
                src = 'upcoming(' + items.length + ')';
            } catch (e) {
                return JSON.stringify({error: String(e)});
            }
        }
        out.sort((a, b) => new Date(a.due) - new Date(b.due));
        const future = out.filter(x => new Date(x.due).getTime() > Date.now() - 86400000);
        return JSON.stringify({src: src, items: future.slice(0, 20)});
        """
        let raw = try await eval(body)
        log("DDL raw: \(raw.prefix(200))")
        let data = Data(raw.utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let err = obj["error"] as? String { log("DDL 获取失败: \(err)"); return [] }
        if let src = obj["src"] as? String { log("DDL 来源: \(src)") }
        guard let arr = obj["items"], let d = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        var items = (try? JSONDecoder().decode([UpcomingEvent].self, from: d)) ?? []
        for i in items.indices where (items[i].url ?? "").isEmpty {
            items[i].url = ddlFallbackURL(items[i])
        }
        return items
    }

    func resolvePublicURL(fileId: Int64) async -> (name: String?, link: String?, size: Int64?) {
        let body = """
        try {
            const r = await fetch('/api/v1/files/\(fileId)/public_url', {credentials: 'include'});
            if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
            return JSON.stringify(await r.json());
        } catch (e) { return JSON.stringify({error: String(e)}); }
        """
        guard let raw = try? await eval(body),
              let data = raw.data(using: .utf8),
              let pu = try? JSONDecoder().decode(PublicURL.self, from: data),
              let link = pu.link else { return (nil, nil, nil) }
        return (pu.display_name ?? nameFromURL(link), link, pu.size)
    }

    func download(fileId: Int64, name: String, link: String?, sizeHint: Int64, to dir: URL) async throws -> URL {
        var fileName = name
        var urlString = link
        var knownSize = sizeHint
        if urlString == nil {
            let pu = await resolvePublicURL(fileId: fileId)
            urlString = pu.link
            if fileName.isEmpty { fileName = pu.name ?? "" }
            if let s = pu.size { knownSize = max(knownSize, s) }
        }
        if fileName.isEmpty { fileName = "file-\(fileId)" }

        // 兜底过滤：名字/大小只有在解析 public_url 后才拿到的场景
        if let kind = skipKind(name: fileName, size: knownSize) {
            throw SkippedFile(kind: kind, name: fileName, size: knownSize)
        }

        // 路线 A：public_url 直链 + URLSession
        if let urlString, let url = URL(string: urlString) {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 {
                    let dest = destURL(dir: dir, fileId: fileId, name: fileName)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    log("下载OK fid=\(fileId) \(dest.lastPathComponent)")
                    return dest
                }
                log("A路 HTTP \(code) fid=\(fileId)，转B路")
            } catch {
                log("A路异常 fid=\(fileId): \(error.localizedDescription)，转B路")
            }
        } else {
            log("public_url 解析失败 fid=\(fileId)")
        }
        // 路线 B：页内 fetch blob → base64 分片
        let data = try await webviewDownload(fileId: fileId)
        let dest = destURL(dir: dir, fileId: fileId, name: fileName)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest, options: .atomic)
        log("下载OK(B路) fid=\(fileId) \(dest.lastPathComponent)")
        return dest
    }

    func destURL(dir: URL, fileId: Int64, name: String) -> URL {
        let clean = sanitizeName(name)
        let dest = dir.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dir.appendingPathComponent("[\(fileId)] " + clean)
        }
        return dest
    }

    func webviewDownload(fileId: Int64) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            pending[fileId] = cont
            let script = """
            void (async () => {
                try {
                    const pr = await fetch('/api/v1/files/\(fileId)/public_url', {credentials: 'include'});
                    if (!pr.ok) throw new Error('public_url HTTP ' + pr.status);
                    const pj = await pr.json();
                    const link = pj.public_url || pj.url;
                    if (!link) throw new Error('no public_url in response');
                    const r = await fetch(link, {credentials: 'include'});
                    if (!r.ok) throw new Error('download HTTP ' + r.status);
                    const buf = await r.arrayBuffer();
                    const bytes = new Uint8Array(buf);
                    let bin = '';
                    const CH = 0x8000;
                    for (let i = 0; i < bytes.length; i += CH)
                        bin += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + CH, bytes.length)));
                    const b64 = btoa(bin);
                    const CH2 = 1 << 20;
                    const n = Math.max(1, Math.ceil(b64.length / CH2));
                    for (let i = 0; i < n; i++)
                        window.webkit.messageHandlers.sync.post({kind: 'chunk', fid: \(fileId), i: i, data: b64.slice(i * CH2, (i + 1) * CH2)});
                    window.webkit.messageHandlers.sync.post({kind: 'done', fid: \(fileId)});
                } catch (e) {
                    window.webkit.messageHandlers.sync.post({kind: 'fail', fid: \(fileId), error: String(e)});
                }
            })();
            """
            if let wv = webView {
                wv.evaluateJavaScript(script, completionHandler: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, self.pending[fileId] != nil else { return }
                self.pending[fileId] = nil
                self.chunks[fileId] = nil
                cont.resume(throwing: NSError(domain: "CanvasBar", code: -2,
                                              userInfo: [NSLocalizedDescriptionKey: "下载超时 fid=\(fileId)"]))
            }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        if kind == "chunk", let fid = (body["fid"] as? NSNumber)?.int64Value,
           let data = body["data"] as? String, let i = (body["i"] as? NSNumber)?.intValue {
            chunks[fid, default: [:]][i] = data
        } else if kind == "done", let fid = (body["fid"] as? NSNumber)?.int64Value {
            let parts = chunks[fid] ?? [:]
            chunks[fid] = nil
            let b64 = parts.sorted { $0.key < $1.key }.map(\.value).joined()
            let cont = pending.removeValue(forKey: fid)
            if let data = Data(base64Encoded: b64) {
                cont?.resume(returning: data)
            } else {
                cont?.resume(throwing: NSError(domain: "CanvasBar", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: "base64 解码失败"]))
            }
        } else if kind == "fail", let fid = (body["fid"] as? NSNumber)?.int64Value {
            let msg = body["error"] as? String ?? "unknown"
            let cont = pending.removeValue(forKey: fid)
            chunks[fid] = nil
            cont?.resume(throwing: NSError(domain: "CanvasBar", code: -3,
                                           userInfo: [NSLocalizedDescriptionKey: msg]))
        }
    }

    // MARK: Manifest

    func loadManifest() -> Manifest {
        guard let data = try? Data(contentsOf: supportDir.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return m
    }

    func saveManifest(_ m: Manifest) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: supportDir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    // MARK: 外部链接

    func loadLinksMap() -> LinkMap {
        guard let data = try? Data(contentsOf: supportDir.appendingPathComponent("links.json")),
              let m = try? JSONDecoder().decode(LinkMap.self, from: data) else { return [:] }
        return m
    }

    func saveLinksMap(_ m: LinkMap) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: supportDir.appendingPathComponent("links.json"), options: .atomic)
        }
    }
}

// MARK: - 打开方式（可用 App 列表 / 用指定 App 打开）

enum OpenWith {
    struct AppOption: Identifiable, Hashable {
        let url: URL
        let name: String
        let isDefault: Bool
        var id: String { url.path }
    }

    private static var cache: [String: [AppOption]] = [:]

    /// 能打开该文件的 App：默认 App 置顶（标记 isDefault），其余按名称排序
    static func apps(for fileURL: URL) -> [AppOption] {
        if let c = cache[fileURL.path] { return c }
        let ws = NSWorkspace.shared
        let fm = FileManager.default
        var out: [AppOption] = []
        if let d = ws.urlForApplication(toOpen: fileURL) {
            out.append(AppOption(url: d, name: fm.displayName(atPath: d.path), isDefault: true))
        }
        var seen = Set(out.map { $0.url.path })
        var rest: [AppOption] = []
        for u in ws.urlsForApplications(toOpen: fileURL) where !seen.contains(u.path) {
            seen.insert(u.path)
            rest.append(AppOption(url: u, name: fm.displayName(atPath: u.path), isDefault: false))
        }
        rest.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        out.append(contentsOf: rest)
        cache[fileURL.path] = out
        return out
    }

    static func open(_ fileURL: URL, with appURL: URL) {
        let appName = FileManager.default.displayName(atPath: appURL.path)
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err {
                log("打开方式失败（\(appName)）: \(err.localizedDescription)")
            }
        }
        log("打开方式: \(fileURL.lastPathComponent) ← \(appName)")
    }

    /// 「其他…」：选任意 App 打开
    @MainActor
    static func chooseAppAndOpen(_ fileURL: URL) {
        let p = NSOpenPanel()
        p.message = "选择用于打开「\(fileURL.lastPathComponent)」的应用"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.application]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let app = p.url else { return }
        open(fileURL, with: app)
    }
}

// MARK: - 检查更新 / 一键更新（GitHub Releases）

enum Updater {
    static let repo = "chescheswu/CanvasBar"

    /// 当前版本：优先 Info.plist；环境变量 CANVASBAR_VERSION_OVERRIDE 可覆盖（更新链路实测用）
    static var currentVersion: String {
        if let v = ProcessInfo.processInfo.environment["CANVASBAR_VERSION_OVERRIDE"],
           !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    struct Release: Decodable {
        let tag_name: String
        let name: String?
        let html_url: String
        let published_at: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(m) = self { return m }
            return nil
        }
    }

    static func versionTuple(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " vV"))
            .split(separator: ".")
            .map { Int(String($0.prefix(while: { $0.isNumber }))) ?? 0 }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = versionTuple(remote), b = versionTuple(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.message("无效的 API 地址")
        }
        var req = URLRequest(url: url)
        req.setValue("CanvasBar-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw UpdateError.message("GitHub 返回 HTTP \(code)（仓库 \(repo) 暂无 Release？）")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// 菜单「⬆️ 检查更新…」入口
    @MainActor
    static func checkFromMenu() {
        let state = AppState.shared
        state.progress = "正在检查更新…"
        Task { @MainActor in
            do {
                let rel = try await fetchLatest()
                state.progress = ""
                if isNewer(rel.tag_name, than: currentVersion) {
                    promptUpdate(rel)
                } else {
                    let a = NSAlert()
                    a.messageText = "已是最新版本（v\(currentVersion)）"
                    var info = "GitHub 最新 Release：\(rel.tag_name)"
                    if let d = rel.published_at { info += "（\(d.prefix(10)) 发布）" }
                    a.informativeText = info
                    a.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    _ = a.runModal()
                }
            } catch {
                state.progress = ""
                log("检查更新失败: \(error.localizedDescription)")
                let a = NSAlert()
                a.messageText = "检查更新失败"
                a.informativeText = "\(error.localizedDescription)\n可稍后重试，或直接打开 GitHub 发布页查看。"
                a.addButton(withTitle: "好")
                a.addButton(withTitle: "打开发布页")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertSecondButtonReturn,
                   let u = URL(string: "https://github.com/\(repo)/releases") {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    @MainActor
    static func promptUpdate(_ rel: Release) {
        let a = NSAlert()
        a.messageText = "发现新版本 \(rel.tag_name)（当前 v\(currentVersion)）"
        var info = ""
        if let d = rel.published_at { info += "发布于 \(d.prefix(10))\n" }
        if let n = rel.name, !n.isEmpty { info += "\(n)\n" }
        info += "\n「一键更新」将自动下载、校验、替换并重启，无需其它操作。\n更新后首次启动可能重新弹出「文稿文件夹」访问授权（应用签名变化所致，属正常现象）。"
        a.informativeText = info
        a.addButton(withTitle: "一键更新")
        a.addButton(withTitle: "查看 Release 页面")
        a.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            performUpdate(rel)
        } else if r == .alertSecondButtonReturn, let u = URL(string: rel.html_url) {
            NSWorkspace.shared.open(u)
        }
    }

    /// 一键更新：下载 → 解压校验 → 后台替换脚本 → 退出重启
    @MainActor
    static func performUpdate(_ rel: Release) {
        let state = AppState.shared
        let targetApp = Bundle.main.bundlePath
        let parentDir = (targetApp as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parentDir) else {
            fallbackToReleasePage(rel, why: "当前 App 所在目录不可写（\(parentDir)），无法自动更新。")
            return
        }
        guard let asset = rel.assets.first(where: { $0.name.hasSuffix("universal.zip") })
                ?? rel.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            fallbackToReleasePage(rel, why: "该 Release 未附带 zip 安装包。")
            return
        }
        state.progress = "正在下载 \(asset.name) …"
        Task { @MainActor in
            do {
                let zip = try await download(asset)
                state.progress = "下载完成，正在解压与校验…"
                let staged = try stage(zip: zip, expectVersion: rel.tag_name)
                state.progress = "更新包就绪，正在重启替换…"
                try applyAndRelaunch(stagedApp: staged, targetApp: targetApp, zip: zip)
            } catch {
                state.progress = ""
                log("更新失败: \(error.localizedDescription)")
                let a = NSAlert()
                a.messageText = "更新失败"
                a.informativeText = "\(error.localizedDescription)\n已保留当前版本，可稍后重试。"
                a.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                _ = a.runModal()
            }
        }
    }

    @MainActor
    static func fallbackToReleasePage(_ rel: Release, why: String) {
        let a = NSAlert()
        a.messageText = "无法自动更新"
        a.informativeText = "\(why)\n已为你打开 Release 页面，可手动下载安装。"
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        _ = a.runModal()
        if let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
    }

    static func download(_ asset: Release.Asset) async throws -> URL {
        guard let url = URL(string: asset.browser_download_url) else {
            throw UpdateError.message("无效的下载地址")
        }
        var req = URLRequest(url: url)
        req.setValue("CanvasBar-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw UpdateError.message("下载失败（HTTP \(code)）") }
        let dir = supportDir.appendingPathComponent("update", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: dst)   // App 自有暂存目录，清理旧包
        try FileManager.default.moveItem(at: tmp, to: dst)
        log("更新包已下载: \(dst.path)")
        return dst
    }

    /// 解压 + 校验（版本号、签名、去隔离属性），返回包内 CanvasBar.app 路径
    static func stage(zip: URL, expectVersion: String) throws -> URL {
        let dir = supportDir.appendingPathComponent("update/stage", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)   // 清理上次暂存
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else {
            throw UpdateError.message("解压失败（安装包可能不完整）")
        }
        guard let app = firstApp(in: dir) else {
            throw UpdateError.message("安装包内未找到 CanvasBar.app")
        }
        let v = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
        let expect = expectVersion.trimmingCharacters(in: CharacterSet(charactersIn: " vV"))
        guard !v.isEmpty, v == expect else {
            throw UpdateError.message("版本校验失败（包内 v\(v) ≠ 期望 v\(expect)）")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.message("签名校验未通过（安装包可能被篡改）")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        log("更新包校验通过: v\(v) @ \(app.path)")
        return app
    }

    static func firstApp(in dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension == "app" {
            return u
        }
        return nil
    }

    @discardableResult
    static func run(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 写替换脚本（等待本进程退出 → 换包 → 重启；失败自动回滚），随后本进程退出
    @MainActor
    static func applyAndRelaunch(stagedApp: URL, targetApp: String, zip: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let udir = supportDir.appendingPathComponent("update", isDirectory: true)
        let script = udir.appendingPathComponent("apply_update.sh")
        let oldBackup = udir.appendingPathComponent("CanvasBar-old.app").path
        let logPath = udir.appendingPathComponent("apply.log").path
        let stageDir = stagedApp.deletingLastPathComponent().deletingLastPathComponent().path

        let sh = """
        #!/bin/zsh
        exec >> "\(logPath)" 2>&1
        echo "[update] $(date '+%F %T') 等待旧实例退出（pid \(pid)）…"
        for i in {1..200}; do /bin/kill -0 \(pid) 2>/dev/null || break; sleep 0.3; done
        sleep 0.5
        if [ -d "\(oldBackup)" ]; then /usr/bin/trash "\(oldBackup)" >/dev/null 2>&1 || true; fi
        if /bin/mv "\(targetApp)" "\(oldBackup)"; then
            if /usr/bin/ditto "\(stagedApp.path)" "\(targetApp)"; then
                /usr/bin/xattr -dr com.apple.quarantine "\(targetApp)" >/dev/null 2>&1 || true
                echo "[update] 替换完成，重启：\(targetApp)"
                /usr/bin/open "\(targetApp)"
                /usr/bin/trash "\(oldBackup)" >/dev/null 2>&1 || true
                /usr/bin/trash "\(stageDir)" >/dev/null 2>&1 || true
                /usr/bin/trash "\(zip.path)" >/dev/null 2>&1 || true
            else
                echo "[update] ditto 失败，回滚旧版本"
                /bin/mv "\(oldBackup)" "\(targetApp)"
                /usr/bin/open "\(targetApp)"
            fi
        else
            echo "[update] 无法移动旧 App（\(targetApp)）"
        fi
        """
        try sh.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        try p.run()
        log("更新：替换脚本已启动，应用即将退出以便替换")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { NSApp.terminate(nil) }
    }
}

// MARK: - 菜单 UI

struct MenuContent: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Text("Canvas 课业同步 · \(state.lastSyncText)")
            .onAppear { Task { await state.refreshLibrary() } }

        Divider()

        if state.upcomingSoon.isEmpty {
            Text("⏰ 暂无近期待办")
        } else {
            Text("⏰ 最近 DDL（点开可标记已提交）")
            ForEach(Array(state.upcomingSoon.prefix(5))) { e in
                Menu("📅  " + state.ddlText(for: e)) {
                    if let s = e.url, !s.isEmpty, let u = URL(string: s) {
                        Button("🌐 在 Canvas 打开") { NSWorkspace.shared.open(u) }
                    }
                    Button("✅ 标记为已提交（不再提醒）") { state.markDdlDone(e) }
                    if state.isManualDdl(e) {
                        Divider()
                        Button("🗑 删除此 Deadline") { state.removeManualDdl(e) }
                    }
                }
            }
        }
        Button("➕ 添加 Deadline…（选课程与日期）") { DdlUI.promptAdd() }
        if !state.ddlDone.isEmpty {
            Button("↩️ 恢复已忽略的 DDL（\(state.ddlDone.count)）") { state.restoreDdlDone() }
        }

        Divider()

        ForEach(state.courses) { c in
            Menu(courseLabel(c)) {
                Button("🌐 在 Canvas 打开课程") {
                    openOnCanvas(c)
                }
                Button("📂 打开课程文件夹") {
                    openFolder(c.url)
                    state.clearNew(c.id)
                }
                if !state.syncDisabled.contains(c.id) {
                    Button("🔄 立即同步此课程") {
                        Task { await SyncEngine.shared.syncAll(only: [c.id]) }
                    }
                    .disabled(state.isSyncing)
                }
                let extLinks = state.linksFor(c.id)
                if !extLinks.isEmpty {
                    Divider()
                    ForEach(extLinks) { l in
                        Button("🔗 \(l.title)") {
                            if let u = URL(string: l.url) {
                                NSWorkspace.shared.open(u)
                                log("菜单打开外部链接: \(l.url)")
                            }
                        }
                    }
                }
                let nodes = state.menuNodes(for: c)
                if nodes.isEmpty {
                    Divider()
                    Button("（暂无同步文件）") {}.disabled(true)
                } else {
                    Divider()
                    MenuTreeView(nodes: nodes, course: c)
                }
                Divider()
                if state.syncDisabled.contains(c.id) {
                    Button("✅ 恢复同步该课程") {
                        state.setSyncEnabled(c.id, true)
                        state.progress = "已恢复同步：\(c.name)"
                        log("用户恢复课程同步: \(c.name) [\(c.id)]")
                    }
                } else {
                    Button("🚫 关闭该课程（停止同步）…") { CoursesUI.confirmClose(c) }
                }
            }
        }

        if state.newTotal > 0 {
            Button("✅ 新内容全部标为已读（\(state.newTotal)）") { state.clearAllNew() }
        }

        Divider()

        Button(state.isSyncing ? "⏳ 同步中…" : "🔄 立即同步") {
            Task { await SyncEngine.shared.syncAll() }
        }
        .disabled(state.isSyncing)

        Menu("☑️ 同步范围（按课程勾选）") {
            ForEach(state.courses) { c in
                Toggle(c.name, isOn: Binding(
                    get: { !state.syncDisabled.contains(c.id) },
                    set: { state.setSyncEnabled(c.id, $0) }))
            }
        }

        Toggle("🎬 跳过视频（保留在线链接）", isOn: Binding(
            get: { state.skipVideos },
            set: { state.setSkipVideos($0) }))
        Toggle("📏 跳过 ≥\(bigFileLimitMB)MB 文件（保留在线链接）", isOn: Binding(
            get: { state.skipBig },
            set: { state.setSkipBig($0) }))

        Divider()

        Button("🔑 登录 Canvas…") { SyncEngine.shared.showLogin() }
        Button("📂 打开同步库（Canvas 同步）") { openFolder(syncRoot) }
        Button("⚙️ 设置 Canvas 域名…（\(Cfg.host)）") { ConfigUI.promptOrigin() }
        Button("📄 查看日志") { NSWorkspace.shared.open(logURL) }
        Button("⬆️ 检查更新…") { Updater.checkFromMenu() }

        Toggle("🚀 开机自动启动", isOn: Binding(
            get: { state.autoStartOn },
            set: { v in
                state.autoStartOn = v
                AutoStart.set(v)
            }))

        if !state.progress.isEmpty {
            Divider()
            Text(state.progress)
        }

        Divider()

        Button("退出 CanvasBar") { NSApp.terminate(nil) }
    }

    func courseLabel(_ c: CachedCourse) -> String {
        let n = state.newFiles[c.id]?.count ?? 0
        let off = state.syncDisabled.contains(c.id) ? "　⏸" : ""
        return n > 0 ? "📚  \(c.name)　🆕 \(n)\(off)" : "📚  \(c.name)\(off)"
    }

    func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// 在默认浏览器打开该课程的 Canvas 页面
    func openOnCanvas(_ c: CachedCourse) {
        guard let u = URL(string: "\(Cfg.origin)/courses/\(c.id)") else { return }
        NSWorkspace.shared.open(u)
        log("菜单打开 Canvas 课程页: \(c.name) → \(u.absoluteString)")
    }
}

/// 课程子菜单的文件树（递归：目录 → 子菜单，文件 → 操作组子菜单；按用户整理的文件夹结构展示）
struct MenuTreeView: View {
    let nodes: [MenuNode]
    let course: CachedCourse
    @ObservedObject var state = AppState.shared

    var body: some View {
        ForEach(nodes) { n in
            if n.isDir {
                Menu("📁 " + n.name) {
                    MenuTreeView(nodes: n.children, course: course)
                    Divider()
                    Button("📍 在 Finder 中显示") { state.revealNode(course, n) }
                }
            } else {
                Menu(state.isNewFile(course.id, n.name) ? "🆕 \(n.name)" : n.name) {
                    FileActionsMenu(course: course, node: n)
                }
            }
        }
    }
}

/// 文件级操作组：打开（默认应用）/ 打开方式（系统可用 App 列表）/ 在 Finder 中显示
struct FileActionsMenu: View {
    let course: CachedCourse
    let node: MenuNode
    @ObservedObject var state = AppState.shared

    var body: some View {
        Button("打开（默认应用）") { state.openNode(course, node) }
        if let fileURL = existingFileURL {
            let apps = OpenWith.apps(for: fileURL)
            if !apps.isEmpty {
                Menu("打开方式") {
                    ForEach(Array(apps.prefix(12))) { a in
                        Button {
                            OpenWith.open(fileURL, with: a.url)
                        } label: {
                            Label {
                                Text(a.isDefault ? "\(a.name)（默认）" : a.name)
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path))
                            }
                        }
                    }
                    Divider()
                    Button("其他…（选择应用）") { OpenWith.chooseAppAndOpen(fileURL) }
                }
            }
        }
        Divider()
        Button("📍 在 Finder 中显示") { state.revealNode(course, node) }
    }

    /// 文件当前有效路径（失效则不给「打开方式」列表，打开仍可走自愈找回）
    private var existingFileURL: URL? {
        guard let p = node.path, FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }
}

/// 课程级操作（关闭同步需确认）
enum CoursesUI {
    @MainActor
    static func confirmClose(_ c: CachedCourse) {
        let a = NSAlert()
        a.messageText = "关闭「\(c.name)」的同步？"
        a.informativeText = "已同步的文件会原样保留在课程文件夹中（子菜单里仍可打开），但从现在起不再检查、下载该课程的新内容。可随时在子菜单里恢复。"
        a.addButton(withTitle: "关闭同步")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let st = AppState.shared
        st.setSyncEnabled(c.id, false)
        st.clearNew(c.id)
        st.progress = "🚫 已关闭同步：\(c.name)（已同步文件保留）"
        log("用户关闭课程同步: \(c.name) [\(c.id)]")
    }
}

enum ConfigUI {
    @MainActor
    static func promptOrigin() {
        let alert = NSAlert()
        alert.messageText = "设置 Canvas 域名"
        alert.informativeText = "同步与登录使用的 Canvas 站点地址。默认 PolyU；分发给他机使用时改成对应的 Canvas 域名即可。修改后需重新登录。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tf.stringValue = Cfg.origin
        tf.placeholderString = Cfg.defaultOrigin
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v != Cfg.origin else { return }
        Cfg.save(origin: v)
        log("Canvas 域名已改为 \(Cfg.origin)")
        AppState.shared.progress = "✅ 域名已更新为 \(Cfg.host)，请重新登录并同步"
    }
}

// MARK: - 手动添加 DDL 对话框（AppKit 纯 frame 布局；swiftc 下 SwiftUI @State 不可用）

enum DdlUI {
    @MainActor
    static func promptAdd() {
        let state = AppState.shared
        guard !state.courses.isEmpty else {
            let a = NSAlert()
            a.messageText = "还没有课程列表"
            a.informativeText = "请先「登录 Canvas」并同步一次，取得课程列表后再手动添加 Deadline。"
            a.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            _ = a.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "添加 Deadline"
        alert.informativeText = "选择课程并填写截止时间。手动 DDL 与 Canvas 同步的 DDL 一起参与菜单栏提醒，可在菜单里单独删除。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let W: CGFloat = 380
        let rowH: CGFloat = 26, gap: CGFloat = 10, labW: CGFloat = 64
        let H = rowH * 3 + gap * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: W - labW, height: 24))
        titleField.placeholderString = "标题（如：Essay 初稿）"

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: W - labW, height: 26), pullsDown: false)
        popup.addItems(withTitles: state.courses.map(\.name))

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: W - labW, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = defaultDueDate()

        func addRow(_ i: Int, _ label: String, _ control: NSView) {
            let top = H - CGFloat(i) * (rowH + gap)
            let center = top - rowH / 2
            let lab = NSTextField(labelWithString: label)
            lab.font = .systemFont(ofSize: 12, weight: .medium)
            lab.alignment = .right
            lab.frame = NSRect(x: 0, y: center - 8, width: labW - 8, height: 16)
            var f = control.frame
            f.origin = NSPoint(x: labW, y: center - f.height / 2)
            control.frame = f
            container.addSubview(lab)
            container.addSubview(control)
        }
        addRow(0, "标题", titleField)
        addRow(1, "课程", popup)
        addRow(2, "截止时间", picker)

        alert.accessoryView = container
        alert.window.initialFirstResponder = titleField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "未命名 Deadline" }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < state.courses.count else { return }
        let course = state.courses[idx]
        state.addManualDdl(title: title, courseId: course.id, date: picker.dateValue)
        state.progress = "✍️ 已添加 Deadline：\(course.name) · \(title)"
    }

    /// 默认截止时间：明天的 23:59
    static func defaultDueDate() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var comp = cal.dateComponents([.year, .month, .day], from: tomorrow)
        comp.hour = 23
        comp.minute = 59
        return cal.date(from: comp) ?? tomorrow
    }
}

struct MenuLabel: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "graduationcap.fill")
            if let d = state.nearestDays {
                Text(d <= 0 ? "今天" : "\(d)d")
            }
        }
    }
}

// MARK: - App 入口

@main
struct CanvasBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuLabel()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        trimLogIfNeeded()
        // v2.6：应用图标（取 bundle 内 AppIcon.icns；对话框等系统界面使用）
        if let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let ic = NSImage(contentsOf: u) {
            NSApp.applicationIconImage = ic
        }
        Cfg.load()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        log("CanvasBar v\(Updater.currentVersion) 启动 | canvas=\(Cfg.origin) | 库=\(syncRoot.path) | macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AppState.shared.reloadManifest()
        let mi = AppState.shared.manifest
        log("菜单文件索引: \(mi.count) 门课 / \(mi.values.reduce(0) { $0 + $1.count }) 个文件")

        Task { @MainActor in
            AppState.shared.consumeAddDdlHook()
            await AppState.shared.refreshLibrary(force: true)
            let engine = SyncEngine.shared
            let loggedIn = (try? await engine.checkSession(force: false)) == true
            if loggedIn {
                let due = AppState.shared.lastSync.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
                let forced = consumeSyncRequest()
                if due || forced { await engine.syncAll() }
            } else if AppState.shared.lastSync == nil {
                engine.state.progress = "首次使用：请登录 Canvas"
                engine.showLogin()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in
                let state = AppState.shared
                state.consumeAddDdlHook()
                await state.refreshLibrary()
                guard !state.isSyncing else { return }
                await SyncEngine.shared.keepAlive()   // 30 分钟心跳：续期会话 / 静默重登（不弹窗）
                let due = state.lastSync.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? false
                let forced = consumeSyncRequest()
                guard due || forced else { return }
                if (try? await SyncEngine.shared.checkSession(force: false)) == true {
                    await SyncEngine.shared.syncAll()
                }
            }
        }
    }
}
