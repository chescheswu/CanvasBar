// CanvasBar — macOS 菜单栏 Canvas 课业同步工作台 (v2.8)
// 课程列表 → 一键开同步文件夹 / 在 Canvas 打开课程页；自动同步 Canvas 材料（模块 ∪ 公告附件 ∪ 页面正文引用，含 front_page）→ ~/Documents/Canvas 同步/<课程>/；
// 库内去重；跳过视频/大文件（保留在线链接）；DDL 可标记已提交/手动添加（选课程+日期）；每课新内容角标；按课程勾选同步；课程子菜单列出已同步文件（悬停展开、点击直开）+ 在 Canvas 打开课程；开机自启；应用图标（Canvas 花标，对话框/Finder 显示）
// v2.7：子菜单按用户整理的文件夹结构展示（磁盘实时扫描）；子菜单可「关闭/恢复该课程同步」（关闭需确认，已下载文件保留）；单独同步某课程；登录窗健壮化（弹窗/重定向收敛到应用内、SAML 递交协助、登录态 Cookie 变化检测、登录窗手动关闭回退）
// v2.8：登录态持久化——会话检查「快路 + SSO 静默重登」（Canvas session 过期时靠 ADFS 持久 cookie 自动回流，不再动辄弹登录窗）；30 分钟心跳保活（应用运行期间会话不再空闲过期）；登录页「保持登录」复选框自动勾选
// v2.9：文件子菜单改「操作组」——打开（默认）/ 打开方式（系统可用 App 列表 + 其他…）/ 在 Finder 中显示（目录同）；新增「⬆️ 检查更新…」+ 一键更新（连 GitHub Releases：下载 zip → ditto 解压 → 版本 + 签名校验 → 后台脚本替换并重启）
// v2.14：菜单栏改原生 NSStatusItem + NSMenu，逐级按需展开（打开方式列表进到文件那一级才算）；空闲占用 138MB → 37MB，打开菜单 216MB → 50MB
// 运行时配置：~/Library/Application Support/CanvasBar/config.json（Canvas 域名，便于分发他机使用）
import AppKit
import Combine
import WebKit
import ServiceManagement
import UniformTypeIdentifiers
import Security

// MARK: - 常量

// ★ 唯一写入边界：插件所有下载统一落在 ~/Documents/Canvas 同步/，不碰用户其他目录
let syncRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/Canvas 同步", isDirectory: true)

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CanvasBar", isDirectory: true)

let logURL = supportDir.appendingPathComponent("log.txt")

// MARK: - 运行时配置（config.json 可改 Canvas 域名、同步频率、课程短名；换学校/换机器只动这里）

enum Cfg {
    static let defaultOrigin = "https://canvas.polyu.edu.hk"
    static let defaultSyncIntervalMinutes = 120
    static let syncIntervalPresets: [(minutes: Int, label: String)] = [
        (30, "每 30 分钟"),
        (120, "每 2 小时（默认）"),
        (360, "每 6 小时"),
        (1200, "每天一次（20 小时）"),
    ]

    private static let lock = NSLock()
    private static var _origin = defaultOrigin
    private static var _host: String = URL(string: defaultOrigin)?.host ?? ""
    private static var _syncIntervalMinutes = defaultSyncIntervalMinutes
    private static var _displayOverrides: [Int64: String] = [:]

    static var origin: String { lock.lock(); defer { lock.unlock() }; return _origin }
    static var host: String { lock.lock(); defer { lock.unlock() }; return _host }
    static var syncIntervalMinutes: Int { lock.lock(); defer { lock.unlock() }; return _syncIntervalMinutes }

    static var configURL: URL { supportDir.appendingPathComponent("config.json") }

    static func load() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let o = obj["canvasOrigin"] as? String { apply(o) }
        if let mins = (obj["syncIntervalMinutes"] as? NSNumber)?.intValue {
            let clamped = max(15, mins)
            lock.lock(); _syncIntervalMinutes = clamped; lock.unlock()
        }
        if let rawOverrides = obj["displayOverrides"] as? [String: String] {
            var parsed: [Int64: String] = [:]
            for (k, v) in rawOverrides {
                if let cid = Int64(k), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsed[cid] = v
                }
            }
            lock.lock(); _displayOverrides = parsed; lock.unlock()
        }
    }

    static func apply(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let h = URL(string: s)?.host, !h.isEmpty else { return }
        lock.lock()
        _origin = s
        _host = h
        lock.unlock()
    }

    static func save() {
        lock.lock()
        let curOrigin = _origin
        let curInterval = _syncIntervalMinutes
        let curOverrides = _displayOverrides
        lock.unlock()

        var obj: [String: Any] = [
            "canvasOrigin": curOrigin,
            "syncIntervalMinutes": curInterval,
        ]
        if !curOverrides.isEmpty {
            obj["displayOverrides"] = Dictionary(uniqueKeysWithValues: curOverrides.map { (String($0.key), $0.value) })
        }
        if let d = try? JSONSerialization.data(withJSONObject: obj,
                                               options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: configURL, options: .atomic)
        }
    }

    static func save(origin raw: String) {
        apply(raw)
        save()
    }

    static func save(syncIntervalMinutes mins: Int) {
        let clamped = max(15, mins)
        lock.lock(); _syncIntervalMinutes = clamped; lock.unlock()
        save()
    }

    static func displayOverride(for courseId: Int64) -> String? {
        lock.lock()
        let custom = _displayOverrides[courseId]
        let curOrigin = _origin
        lock.unlock()
        if let custom { return custom }
        if curOrigin == defaultOrigin { return defaultPolyUOverrides[courseId] }
        return nil
    }

    /// 提取可注册父域名（用于跨子域 SSO/会话 cookie 持久化，如 canvas.polyu.edu.hk -> polyu.edu.hk）
    static func cookieRootDomain() -> String {
        let h = host.lowercased()
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return h }
        let suffix2 = parts.suffix(2).joined(separator: ".")
        let threePartSuffixes: Set<String> = ["edu.hk", "ac.uk", "edu.cn", "edu.au", "co.uk", "edu.tw", "edu.sg"]
        if parts.count >= 3 && threePartSuffixes.contains(suffix2) {
            return parts.suffix(3).joined(separator: ".")
        }
        return suffix2
    }
}

private let logQueue = DispatchQueue(label: "local.chester.canvasbar.log")
private let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()

func log(_ s: String) {
    logQueue.sync {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let line = "[\(logDateFormatter.string(from: Date()))] \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }
}

/// 日志裁剪：超过 512KB 时只保留尾部 128KB（防无限增长）
func trimLogIfNeeded() {
    logQueue.sync {
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
}

/// 弹窗并强制置顶（LSUIElement / 无 Dock 模式下确保可见与键盘焦点）
@MainActor
@discardableResult
func showTopAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
    a.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    a.window.level = .modalPanel
    NSApp.activate(ignoringOtherApps: true)
    a.window.orderFrontRegardless()
    a.window.makeKeyAndOrderFront(nil)
    return a.runModal()
}

/// 线程安全共享日期格式化器（避免每次渲染/日志重复构造）
enum DateFmt {
    private static let lock = NSLock()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let mmddHHmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    private static let mmdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    static func formatISO(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return isoPlain.string(from: d)
    }

    static func formatFullDue(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return mmddHHmm.string(from: d)
    }

    static func formatShortDue(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return mmdd.string(from: d)
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

// PolyU 默认课程短名回退（可在 config.json 的 displayOverrides 中覆盖或补充）
let defaultPolyUOverrides: [Int64: String] = [
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

/// 结果盒子：后台线程写、主线程读（NSLock 保证跨线程内存可见性）
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    private var _done = false

    func finish(_ v: T) {
        lock.lock()
        _value = v
        _done = true
        lock.unlock()
    }

    func read() -> (done: Bool, value: T?) {
        lock.lock()
        defer { lock.unlock() }
        return (_done, _value)
    }
}

/// 同步库实时扫描出的一个文件（相对课程文件夹的子目录路径 + 文件名 + 绝对路径）
struct LibEntry {
    let dirs: [String]     // 相对子目录（[] = 课程文件夹根下）
    let name: String
    let path: String
}

/// 课程子菜单的树节点：目录或文件（显式 isDir，目录也保留真实磁盘路径）
struct MenuNode: Identifiable {
    let id: String
    let name: String
    let path: String?
    let fid: String?        // manifest 文件 id（可能为 nil）
    let isDir: Bool
    let children: [MenuNode]
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
        DateFmt.parseISO(due)
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
        return DateFmt.formatFullDue(d)
    }

    /// 只到日（一级菜单用；时间放到下级菜单的完整标题里）
    var shortDueText: String {
        guard let d = dueDate else { return due }
        return DateFmt.formatShortDue(d)
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
        if FileManager.default.fileExists(atPath: agentPlist.path) { return true }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        if on {
            // ad-hoc 签名每次更新/重编译都会改变 CDHash，SMAppService 极易失效；
            // 统一使用 LaunchAgent plist（Aqua 会话）确保自启稳定，并清理旧 SMAppService 避免双启
            try? SMAppService.mainApp.unregister()
            writeAgent()
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentPlist)
            log("开机自启：已关闭")
        }
    }

    /// 若已启用 LaunchAgent，启动时校准可执行路径（仅当当前运行在标准安装目录时）
    static func syncPathIfEnabled() {
        guard FileManager.default.fileExists(atPath: agentPlist.path) else { return }
        let bundlePath = Bundle.main.bundlePath
        let stdPrefixes = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        guard stdPrefixes.contains(where: { bundlePath.hasPrefix($0) }) else { return }
        let expectedBin = bundlePath + "/Contents/MacOS/CanvasBar"
        if let dict = NSDictionary(contentsOf: agentPlist) as? [String: Any],
           let args = dict["ProgramArguments"] as? [String],
           args.first == expectedBin {
            return
        }
        writeAgent()
    }

    static func writeAgent() {
        let bin = Bundle.main.bundlePath + "/Contents/MacOS/CanvasBar"
        let plistObj: [String: Any] = [
            "Label": "local.chester.canvasbar",
            "ProgramArguments": [bin],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0)
            try data.write(to: agentPlist, options: .atomic)
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
    private(set) var libLastRefresh: Date?
    private var libCourseRefreshedAt: [Int64: Date] = [:]
    private var libCourseInFlight: Set<Int64> = []

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
        return "上次同步 " + DateFmt.formatFullDue(d)
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

    /// 一级菜单行：只显示「月-日」，课程与标题保留全名（超宽由 MenuMetrics 省略，全名在下级菜单顶部展开）
    func ddlText(for e: UpcomingEvent) -> String {
        let d = e.daysLeft ?? 0
        let tag = d == 0 ? "今天" : "\(d)天后"
        let ctag = courses.first { String($0.id) == e.context }?.name ?? ""
        let prefix = ctag.isEmpty ? "" : "\(ctag)："
        let mark = isManualDdl(e) ? "✍️ " : ""
        return "\(mark)\(e.shortDueText) · \(prefix)\(e.title)（\(tag)）"
    }

    /// 下级菜单顶部：完整标题（含截止时间与全名）
    func ddlFullText(for e: UpcomingEvent) -> String {
        let d = e.daysLeft ?? 0
        let tag = d == 0 ? "今天截止" : "还有 \(d) 天"
        let ctag = courses.first { String($0.id) == e.context }?.name ?? ""
        let prefix = ctag.isEmpty ? "" : "\(ctag)："
        let mark = isManualDdl(e) ? "✍️ 手动添加 · " : ""
        return "\(mark)\(e.dueText) · \(prefix)\(e.title)（\(tag)）"
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
            return Self.buildTree(entries, courseRoot: c.url)
        }
        return menuFiles(for: c.id).map {
            MenuNode(id: "f:" + $0.fid, name: $0.name, path: $0.path, fid: $0.fid, isDir: false, children: [])
        }
    }

    /// 平铺清单 → 目录树（目录优先、自然排序；目录保留真实磁盘路径）
    static func buildTree(_ entries: [LibEntry], courseRoot: URL) -> [MenuNode] {
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
                let dirURL = p.reduce(courseRoot) { $0.appendingPathComponent($1, isDirectory: true) }
                dirsOut.append(MenuNode(id: "d:" + p.joined(separator: "/"), name: name,
                                        path: dirURL.path, fid: nil, isDir: true, children: build(sub, p)))
            }
            dirsOut.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var filesOut: [MenuNode] = d.files.map {
                MenuNode(id: "f:" + (prefix + [$0.name]).joined(separator: "/"),
                         name: $0.name, path: $0.path, fid: nil, isDir: false, children: [])
            }
            filesOut.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return dirsOut + filesOut
        }
        return build(root, [])
    }

    /// 扫描跳过的常见开发/依赖/构建目录，避免课程目录下的代码项目把扫描器拖慢或撑爆上限
    nonisolated static let ignoredScanDirNames: Set<String> = [
        "node_modules", ".venv", "venv", "__pycache__", ".git", ".hg", ".svn",
        "dist", "build", ".build", ".next", ".nuxt", "target", "Pods",
        "DerivedData", ".cache", ".pytest_cache", ".mypy_cache", ".tox",
        ".ipynb_checkpoints", "site-packages", "vendor",
    ]
    nonisolated static let ignoredScanBundleExts: Set<String> = [
        "app", "xcodeproj", "xcworkspace", "framework", "playground",
        "photoslibrary", "bundle", "kext",
    ]

    nonisolated static func shouldSkipScanDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ignoredScanDirNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && ignoredScanBundleExts.contains(ext)
    }

    /// 扫描课程文件夹（同步版本；调用方负责放到后台线程）
    nonisolated static func scanTree(_ root: URL) -> [LibEntry] {
        var out: [LibEntry] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return out }
        let rootPath = root.standardizedFileURL.path
        var seen = 0
        for case let u as URL in en {
            seen += 1
            if seen > 30000 || out.count >= 4000 { break }
            guard let rv = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            if rv.isDirectory == true {
                if shouldSkipScanDirectory(u) { en.skipDescendants() }
                continue
            }
            guard rv.isRegularFile == true else { continue }
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
            box.finish(Self.scanTree(root))
        }
        let steps = Int(timeout / 0.4)
        for _ in 0..<steps {
            let st = box.read()
            if st.done { return st.value ?? [] }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    /// 刷新单门课文件夹实时结构（菜单展开课程时按需触发，30 秒冷却）
    func refreshCourse(_ course: CachedCourse, force: Bool = false) async {
        guard !libCourseInFlight.contains(course.id) else { return }
        if !force, let last = libCourseRefreshedAt[course.id], Date().timeIntervalSince(last) < 30 { return }
        libCourseInFlight.insert(course.id)
        defer { libCourseInFlight.remove(course.id) }
        if let entries = await scanTreeAsync(course.url) {
            libTree[course.id] = entries
            libCourseRefreshedAt[course.id] = Date()
        }
    }

    /// 刷新全部课程文件夹实时结构（启动 / 同步完成后调用；1.5 秒防抖）
    func refreshLibrary(force: Bool = false) async {
        if libRefreshInFlight { return }
        if !force, let last = libLastRefresh, Date().timeIntervalSince(last) < 1.5 { return }
        libRefreshInFlight = true
        libLastRefresh = Date()
        defer { libRefreshInFlight = false }
        let snapshot = courses.map { ($0.id, $0.url) }
        var total = 0
        let now = Date()
        for (id, url) in snapshot {
            if let entries = await scanTreeAsync(url) {
                libTree[id] = entries
                libCourseRefreshedAt[id] = now
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
                showTopAlert(a)
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
                showTopAlert(a)
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
        if let d = DateFmt.parseISO(s) { return DateFmt.formatISO(d) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return DateFmt.formatISO(d) }
        }
        return nil
    }

    func addManualDdl(title: String, courseId: Int64, date: Date) {
        addManualDdl(title: title, courseId: courseId, dueISO: DateFmt.formatISO(date))
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

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class SyncEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = SyncEngine()
    var state: AppState { AppState.shared }

    var webView: WKWebView?
    var hiddenWindow: NSWindow?
    var loginWV: WKWebView?
    var loginWindow: NSWindow?
    var loginTimer: Timer?
    var pendingLoginUser: String?
    var pendingLoginPass: String?
    var lastLoginURLSeen: String?
    var loginCookieSig: String?
    var loginVerifyBusy = false
    var loginVerifyAt: Date?
    var loginFinished = false
    var lastNavError: String?
    var lastNavErrorAt: Date?
    private var activeSessionCheck: Task<Bool, Error>?
    private var pendingSyncAfterLogin = false
    private var samlAutoSubmitCount = 0
    private var lastSamlAutoSubmitURL: String?

    private let noRedirectDelegate = NoRedirectDelegate()
    private lazy var heartbeatSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg, delegate: noRedirectDelegate, delegateQueue: nil)
    }()

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
        win.isOpaque = false
        win.alphaValue = 0          // 不占合成像素
        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        win.contentView = cv
        cv.addSubview(wv)
        win.orderOut(nil)           // 明确不可见：WebKit 照跑 JS/网络，省掉图层合成
        hiddenWindow = win
        log("隐藏 WebView 已创建")
    }

    /// 释放页面、保留壳：Canvas SPA 的 DOM/JS 堆是内存大头，同步完顶成空白页让 WebKit 回收。
    /// 同步或会话检查进行中不得释放，避免互相踩踏。
    func releasePage() {
        guard !state.isSyncing, activeSessionCheck == nil else { return }
        guard let wv = webView, wv.url?.absoluteString != "about:blank" else { return }
        wv.stopLoading()
        wv.loadHTMLString("", baseURL: nil)
        log("已释放 WebView 页面（保留壳）")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === loginWV {
            log("登录窗 page didFinish: \(webView.url?.absoluteString.prefix(120) ?? "nil")")
            Task { @MainActor in self.tryFinishLogin() }
            checkSamlSubmitPage(on: webView)
            checkKmsi(on: webView)
            enablePasswordAutoFill(on: webView)
            autoFillLogin(on: webView)
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

    /// 登录窗被手动关闭：清掉引用 + 停轮询 + 解 delegate，让下次「登录」重新开窗
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === loginWindow else { return }
        if !loginFinished { log("登录窗口已关闭") }
        loginTimer?.invalidate()
        loginTimer = nil
        loginWV?.stopLoading()
        loginWV?.navigationDelegate = nil
        loginWV?.uiDelegate = nil
        loginWindow = nil
        loginWV = nil
        loginFinished = false
        samlAutoSubmitCount = 0
        lastSamlAutoSubmitURL = nil
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

    /// 会话检查（单飞互斥）：快路直接验；疑过期则重载并等 SSO 静默重登（ADFS 持久 cookie 尚在时自动回流，无需用户）
    func checkSession(force: Bool = false) async throws -> Bool {
        if let existing = activeSessionCheck {
            return try await existing.value
        }
        let task = Task<Bool, Error> { @MainActor in
            try await self.performCheckSession(force: force)
        }
        activeSessionCheck = task
        defer { activeSessionCheck = nil }
        return try await task.value
    }

    private func performCheckSession(force: Bool) async throws -> Bool {
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
        try { return document.querySelector('input[type="password"]') ? 'YES' : 'NO'; }
        catch (e) { return 'NO'; }
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
        cfg.userContentController.add(self, name: "login")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.credentialCaptureJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        samlAutoSubmitCount = 0
        lastSamlAutoSubmitURL = nil
        snapshotLoginCookies()
        log("登录窗口已打开")

        loginTimer?.invalidate()
        loginTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                guard self.loginWindow != nil else {
                    t.invalidate()
                    self.loginTimer = nil
                    return
                }
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

    /// 原生 URLSession 轻量保活（零 WebKit 页面内存）：携带 Cookie Store 里的会话 cookie 调 /api/v1/users/self，
    /// 服务端返回 200 即表示 session 真实有效，并将新 Set-Cookie 持久化回 WebKit store。
    func fetchSelfViaURLSession() async -> Bool {
        ensureWebView()
        let store = WKWebsiteDataStore.default().httpCookieStore
        var cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        if cookies.isEmpty {
            // 冷启动时 WebKit 网络进程刚拉起，binarycookies 可能尚未载入内存，稍等重试一次
            try? await Task.sleep(nanoseconds: 350_000_000)
            cookies = await withCheckedContinuation { cont in
                store.getAllCookies { cont.resume(returning: $0) }
            }
        }
        guard let apiURL = URL(string: Cfg.origin + "/api/v1/users/self") else { return false }
        let host = Cfg.host.lowercased()
        let matching = cookies.filter { c in
            var d = c.domain.lowercased()
            while d.hasPrefix(".") { d.removeFirst() }
            return !d.isEmpty && host.hasSuffix(d)
        }
        guard !matching.isEmpty else { return false }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in HTTPCookie.requestHeaderFields(with: matching) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (_, resp) = try await heartbeatSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { k, v -> (String, String)? in
                guard let ks = k as? String, let vs = v as? String else { return nil }
                return (ks, vs)
            })
            let newCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: apiURL)
            if !newCookies.isEmpty {
                let expiry = Date().addingTimeInterval(30 * 24 * 3600)
                for c in newCookies {
                    var props = c.properties ?? [:]
                    props.removeValue(forKey: .discard)
                    if props[.expires] == nil { props[.expires] = expiry }
                    let target = HTTPCookie(properties: props) ?? c
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        store.setCookie(target) { cont.resume() }
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 心跳保活（每 30 分钟）：优先走原生 URLSession 真实续期 Canvas 会话；失效时再尝试静默重登；彻底失败不弹窗
    func keepAlive() async {
        guard !state.isSyncing, loginWindow == nil else { return }
        if webView == nil || webView?.url?.absoluteString == "about:blank" {
            if await fetchSelfViaURLSession() {
                log("心跳: OK（原生请求续期，页面未加载）")
                return
            }
            log("心跳: 服务端会话已失效，尝试静默重登…")
            let ok = (try? await checkSession(force: true)) == true
            log("心跳: 静默重登\(ok ? "成功" : "失败（保持现状，下次同步时再试）")")
            releasePage()
            return
        }
        ensureWebView()
        guard let wv = webView else { return }
        if isCanvasURL(wv.url), !wv.isLoading, await fetchSelfOK(wv) {
            log("心跳: OK")
            persistSessionCookies()   // 服务端会滑动续期，顺手把新 cookie 再落一次盘
            return
        }
        log("心跳: 会话可能已过期，尝试静默重登…")
        let ok = (try? await checkSession(force: true)) == true
        log("心跳: 静默重登\(ok ? "成功" : "失败（保持现状，下次同步时再试）")")
        releasePage()
    }

    /// Canvas 发的是会话 cookie（无 expiresDate），WebKit 只把它留在内存，app 一退就丢。
    /// 这里复制一份并补 30 天有效期写回（保留 HttpOnly / SameSite 等属性），重启后仍可自动续上。
    func persistSessionCookies() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let host = Cfg.host.lowercased()
        let rootDomain = Cfg.cookieRootDomain()
        store.getAllCookies { cookies in
            let expiry = Date().addingTimeInterval(30 * 24 * 3600)
            let targets = cookies.filter { c in
                guard c.expiresDate == nil else { return false }   // 本来就是持久 cookie
                var d = c.domain.lowercased()
                while d.hasPrefix(".") { d.removeFirst() }
                return !d.isEmpty && (host.hasSuffix(d) || d == rootDomain || d.hasSuffix("." + rootDomain))
            }
            guard !targets.isEmpty else { return }
            log("cookie 持久化: 处理 \(targets.count) 条会话 cookie → 30 天")
            for c in targets {
                var props = c.properties ?? [
                    .name: c.name, .value: c.value, .domain: c.domain,
                    .path: c.path.isEmpty ? "/" : c.path,
                ]
                props.removeValue(forKey: .discard)
                props[.expires] = expiry
                if c.isSecure { props[.secure] = "TRUE" }
                guard let m = HTTPCookie(properties: props) else { continue }
                store.setCookie(m) {}
            }
        }
    }

    /// 轻量会话判据：Canvas 域下存在未过期的 session cookie。
    /// 纯本地读 cookie store，不发请求、不加载页面。
    func sessionCookieValid() async -> Bool {
        ensureWebView()   // 先建壳：WebKit 的 cookie store 要等 WebView/网络进程起来才读得到
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        let host = Cfg.host.lowercased()
        let now = Date()
        let mine = cookies.filter { c in
            var d = c.domain.lowercased()
            while d.hasPrefix(".") { d.removeFirst() }
            return !d.isEmpty && host.hasSuffix(d)
        }
        let ok = mine.contains { c in
            (c.expiresDate.map { $0 > now } ?? true) && c.name.lowercased().contains("session")
        }
        if !ok {
            log("cookie 校验: 无有效会话 cookie（本站点现有: \(mine.map(\.name).sorted().joined(separator: ","))）")
        }
        return ok
    }

    /// ADFS/SAML 递交页等待：仅在页面无密码框且存在 SAMLResponse/wresult 隐藏域时介入，且同页最多提交一次、全程上限 2 次
    func checkSamlSubmitPage(on wv: WKWebView) {
        let probe = """
        try {
            if (document.querySelector('input[type="password"]')) return 'LOGIN_FORM';
            var fs = Array.from(document.forms || []);
            var f = fs.find(function(x){
                return !!(x.querySelector && (x.querySelector('input[name="SAMLResponse"]') || x.querySelector('input[name="wresult"]')));
            });
            return f ? 'YES' : 'NO';
        } catch (e) { return 'NO'; }
        """
        Task { @MainActor in
            guard self.loginWV === wv, self.loginWindow != nil, !self.loginFinished else { return }
            guard self.samlAutoSubmitCount < 2 else { return }
            guard let r = try? await self.callJS(probe, on: wv), r == "YES" else { return }
            let u0 = wv.url?.absoluteString
            guard u0 != self.lastSamlAutoSubmitURL else { return }
            log("登录窗：检测到 SAML 递交页，等待自动跳转…")
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard self.loginWV === wv, self.loginWindow != nil, !self.loginFinished,
                  wv.url?.absoluteString == u0, !wv.isLoading, self.samlAutoSubmitCount < 2 else { return }
            let submit = """
            try {
                if (document.querySelector('input[type="password"]')) return 'LOGIN_FORM';
                var fs = Array.from(document.forms || []);
                var f = fs.find(function(x){
                    return !!(x.querySelector && (x.querySelector('input[name="SAMLResponse"]') || x.querySelector('input[name="wresult"]')));
                });
                if (f) { f.submit(); return 'SUBMITTED'; }
                return 'GONE';
            } catch (e) { return 'ERR:' + e; }
            """
            if let r2 = try? await self.callJS(submit, on: wv), r2 == "SUBMITTED" {
                self.samlAutoSubmitCount += 1
                self.lastSamlAutoSubmitURL = u0
                log("登录窗：SAML 递交页 3.5 秒未跳转，已协助提交（第 \(self.samlAutoSubmitCount) 次）")
            }
        }
    }

    /// 登录页若提供「保持登录 / Remember me」（KMSI）复选框 → 自动勾选，让 SSO 会话尽量持久
    func checkKmsi(on wv: WKWebView) {
        let js = """
        try {
            var cbs = Array.from(document.querySelectorAll('input[type=checkbox]'));
            var hit = cbs.find(function(c){ return /kmsi|keep.*(sign|log)|remember|stay.*sign|保持|记住/i.test(
                (c.name||'') + ' ' + (c.id||'') + ' ' + (c.getAttribute('aria-label')||'')); });
            if (!hit) return 'NONE';
            if (hit.checked) return 'ALREADY';
            hit.checked = true;
            hit.dispatchEvent(new Event('change', {bubbles: true}));
            return 'CHECKED';
        } catch (e) { return 'ERR:' + e; }
        """
        Task { @MainActor in
            guard self.loginWV === wv else { return }
            if let r = try? await self.callJS(js, on: wv), r == "CHECKED" {
                log("登录窗：检测到「保持登录」，已自动勾选")
            }
        }
    }

    /// ADFS 登录页的账号/密码 input 没标 autocomplete，WebKit 因此不给系统密码自动填充。
    /// 补上 username / current-password，顺手去掉部分主题用来挡填充的 readonly。
    /// 注意：callAsyncJavaScript 的 body 必须自带 return —— 包成 IIFE 会返回 undefined。
    func enablePasswordAutoFill(on wv: WKWebView) {
        let js = """
        try {
            var u = document.querySelector('input[name="UserName"],input[name="username"],input[type="email"],input[autocomplete="username"]');
            var p = document.querySelector('input[name="Password"],input[name="password"],input[type="password"]');
            var out = [];
            if (u) {
                u.setAttribute('autocomplete', 'username');
                u.removeAttribute('readonly');
                out.push('user=' + (u.name || u.id || u.type));
            }
            if (p) {
                p.setAttribute('autocomplete', 'current-password');
                p.removeAttribute('readonly');
                out.push('pass=' + (p.name || p.id || p.type));
            }
            return out.length ? out.join(' ') : 'NONE';
        } catch (e) { return 'ERR:' + e; }
        """
        Task { @MainActor in
            guard self.loginWV === wv else { return }
            if let r = try? await self.callJS(js, on: wv) {
                log("登录页 AutoFill: \(r)")
            }
        }
    }

    /// 登录窗注入脚本：拦到表单提交就把账号密码交回原生，登录成功后存钥匙串
    static let credentialCaptureJS = """
    document.addEventListener('submit', function(){
        try {
            var p = document.querySelector('input[type="password"]');
            var u = document.querySelector('input[name="UserName"],input[name="username"],input[type="email"]');
            if (p && p.value) {
                window.webkit.messageHandlers.login.postMessage({kind:'credentials', user: (u && u.value) || '', pass: p.value});
            }
        } catch (e) {}
    }, true);
    """

    /// 登录页加载完：钥匙串里有凭据就直接填进表单，免手打。
    /// ADFS 有时在 load 完再清一次表单，1.2 秒后补填一次。
    func autoFillLogin(on wv: WKWebView) {
        LoginVault.load { [weak self] v in
            guard let self, self.loginWV === wv, !self.loginFinished else { return }
            guard let v else {
                if LoginVault.takeMissingNotice() {
                    log("登录页自动填充: 钥匙串无凭据（菜单 →「设置 Canvas 登录账号…」）")
                }
                return
            }
            self.fillLoginForm(on: wv, user: v.user, password: v.password)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard self.loginWV === wv, !self.loginFinished else { return }
                self.fillLoginForm(on: wv, user: v.user, password: v.password)
            }
        }
    }

    /// 把钥匙串凭据灌进 ADFS 表单。密码走 callAsyncJavaScript 的参数传入，不拼进脚本字符串；
    /// 写入后派发 input/change，受控组件才不会把值刷回去。
    func fillLoginForm(on wv: WKWebView?, user: String, password: String) {
        guard let wv else { return }
        let js = """
        var q = function(s){ return document.querySelector(s); };
        var u = q('input[name="UserName"],input[name="username"],input[type="email"]');
        var p = q('input[name="Password"],input[name="password"],input[type="password"]');
        var set = function(el, v){
            var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
        };
        if (u) set(u, user);
        if (p) set(p, password);
        return (u ? 'u' : '-') + (p ? 'p' : '-');
        """
        Task { @MainActor in
            guard self.loginWV === wv else { return }
            do {
                let r = try await wv.callAsyncJavaScript(js, arguments: ["user": user, "password": password],
                                                         in: nil, contentWorld: .page)
                log("登录页填充: \(String(describing: r))")
            } catch {
                log("登录页填充失败: \(error.localizedDescription)")
            }
        }
    }

    func handleLoginMessage(kind: String, body: [String: Any]) {
        switch kind {
        case "fill":
            LoginVault.load { [weak self] v in
                guard let self else { return }
                guard let v else {
                    if LoginVault.takeMissingNotice() { log("登录页填充: 钥匙串无记录") }
                    return
                }
                self.fillLoginForm(on: self.loginWV, user: v.user, password: v.password)
            }
        case "credentials":
            let u = body["user"] as? String ?? ""
            let p = body["pass"] as? String ?? ""
            guard !p.isEmpty else { return }
            pendingLoginUser = u
            pendingLoginPass = p
            log("登录页填充: 已捕获提交的凭据（\(u.isEmpty ? "用户名空" : u)）")
        default:
            break
        }
    }

    func finishLoginSuccess() {
        guard !loginFinished, loginWindow != nil else { return }
        loginFinished = true
        loginTimer?.invalidate()
        loginTimer = nil
        samlAutoSubmitCount = 0
        lastSamlAutoSubmitURL = nil
        log("登录成功")
        loginWindow?.orderOut(nil)
        loginWindow?.close()
        loginWindow = nil
        loginWV = nil
        persistSessionCookies()          // 登录态落盘，重启后不用重登
        if let u = pendingLoginUser, let p = pendingLoginPass, !u.isEmpty, !p.isEmpty {
            LoginVault.save(user: u, password: p)
            log("登录页填充: 凭据已存入钥匙串（\(u)）")
        }
        pendingLoginUser = nil
        pendingLoginPass = nil
        state.progress = "✅ 登录成功，开始同步…"
        if state.isSyncing {
            pendingSyncAfterLogin = true
        } else {
            Task { @MainActor in await self.syncAll() }
        }
    }

    // MARK: 同步主流程

    func syncAll(only: Set<Int64>? = nil) async {
        guard !state.isSyncing else { log("已有同步进行中，跳过"); return }
        state.isSyncing = true
        var runFollowUp = false
        defer {
            state.isSyncing = false
            state.saveState()
            releasePage()          // 同步收尾即卸载页面，避免 Canvas SPA 常驻
            if pendingSyncAfterLogin {
                pendingSyncAfterLogin = false
                runFollowUp = true
            }
            if runFollowUp {
                Task { @MainActor in await self.syncAll() }
            }
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
                let display = Cfg.displayOverride(for: id) ?? shortName(name)
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
                let fetched: (files: [RemoteFile], links: [ExternalLink], allSourcesOK: Bool)? =
                    try? await fetchCourseFiles(courseId: id)
                let files = fetched?.files ?? []
                if let s = fetched, (s.allSourcesOK || !s.links.isEmpty) {
                    linksMap[String(id)] = s.links
                }
                log("课程 \(id) \(name): 共 \(files.count) 个文件条目，外部链接 \(fetched?.links.count ?? 0) 条")
                var cm = manifest[String(id)] ?? [:]
                // 仅当三源全部成功且无接口报错时才清理 stale 记录，防止断网/401 误清整个课程 manifest
                if let s = fetched, s.allSourcesOK {
                    let srcFids = Set(s.files.map { String($0.id) })
                    let stale = cm.keys.filter { !srcFids.contains($0) }
                    if !stale.isEmpty {
                        log("  记录清理: 移除 \(stale.count) 条不再同步的条目")
                        for k in stale { cm.removeValue(forKey: k) }
                    }
                } else if fetched != nil {
                    log("  ⚠️ 部分源请求失败，跳过本轮 stale 记录清理")
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
            persistSessionCookies()   // 同步时服务端刷新过会话，落盘保活
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
            box.finish(Self.scanSync(root))
        }
        let steps = Int(timeout / 0.5)
        for _ in 0..<steps {
            let st = box.read()
            if st.done { return st.value ?? [:] }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// 浅层目录列表（降级用），同样带超时
    func shallowListAsync(_ dir: URL, timeout: Double = 8) async -> [String]? {
        let box = Box<[String]>()
        DispatchQueue.global(qos: .utility).async {
            box.finish((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        }
        let steps = Int(timeout / 0.5)
        for _ in 0..<steps {
            let st = box.read()
            if st.done { return st.value }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    nonisolated static func scanSync(_ root: URL) -> [String: [(size: Int64, path: String)]] {
        var idx: [String: [(size: Int64, path: String)]] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return idx }
        var seen = 0
        for case let u as URL in en {
            seen += 1
            if seen > 20000 { break }  // 保险丝：超大目录不递归到底
            guard let rv = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { continue }
            if rv.isDirectory == true {
                if AppState.shouldSkipScanDirectory(u) { en.skipDescendants() }
                continue
            }
            guard rv.isRegularFile == true else { continue }
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
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": link], format: .xml, options: 0)
            try data.write(to: dest, options: .atomic)
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
    func fetchCourseFiles(courseId: Int64) async throws -> (files: [RemoteFile], links: [ExternalLink], allSourcesOK: Bool) {
        let body = """
        const map = {};
        const add = (fid, name) => {
            const k = String(fid);
            if (!(k in map) || (!map[k] && name)) map[k] = name || '';
        };
        const counts = {mods: 0, anns: 0, pages: 0, bodies: 0, links: 0};
        const errors = [];
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
        } catch (e) { if (!/HTTP 404\\b/.test(String(e))) errors.push('modules:' + String(e)); }
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
        } catch (e) { errors.push('anns:' + String(e)); }
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
        } catch (e) { if (!/HTTP 404\\b/.test(String(e))) errors.push('pages:' + String(e)); }
        counts.links = links.length;
        return JSON.stringify({files: Object.keys(map).map(k => ({id: Number(k), name: map[k] || null})), links: links.slice(0, 20), counts, errors});
        """
        let raw = try await eval(body)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("三源解析失败 course=\(courseId): \(raw.prefix(120))")
            return ([], [], false)
        }
        if let counts = obj["counts"] as? [String: Any] {
            log("  源统计: modules=\(counts["mods"] ?? 0) anns=\(counts["anns"] ?? 0) pages=\(counts["pages"] ?? 0) bodies=\(counts["bodies"] ?? 0) links=\(counts["links"] ?? 0)")
        }
        let errors = (obj["errors"] as? [String]) ?? []
        if !errors.isEmpty {
            log("  ⚠️ 源请求异常 course=\(courseId): \(errors.joined(separator: "; "))")
        }
        var files: [RemoteFile] = []
        if let arr = obj["files"], let fd = try? JSONSerialization.data(withJSONObject: arr) {
            files = (try? JSONDecoder().decode([RemoteFile].self, from: fd)) ?? []
        }
        var extLinks: [ExternalLink] = []
        if let arr = obj["links"], let ld = try? JSONSerialization.data(withJSONObject: arr) {
            extLinks = (try? JSONDecoder().decode([ExternalLink].self, from: ld)) ?? []
        }
        return (files, extLinks, errors.isEmpty)
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
        if fileName.contains("%"), let decoded = fileName.removingPercentEncoding {
            fileName = decoded
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
        guard let wv = webView else { throw SyncError.noWebView }
        return try await withCheckedThrowingContinuation { cont in
            pending[fileId] = cont
            let script = """
            void (async () => {
                const fid = \(fileId);
                try {
                    const pr = await fetch('/api/v1/files/' + fid + '/public_url', {credentials: 'include'});
                    if (!pr.ok) throw new Error('public_url HTTP ' + pr.status);
                    const pj = await pr.json();
                    const link = pj.public_url || pj.url;
                    if (!link) throw new Error('no public_url in response');
                    const r = await fetch(link, {credentials: 'include'});
                    if (!r.ok) throw new Error('download HTTP ' + r.status);
                    if (!r.body || !r.body.getReader) throw new Error('stream unsupported');
                    // 边下边发：只留 48KB 缓冲，不再整文件 arrayBuffer→字符串→base64 三份拷贝
                    const CHUNK = 48 * 1024;              // 3 的倍数 → base64 无 padding，分片可无缝拼接
                    const reader = r.body.getReader();
                    let buf = new Uint8Array(0), seq = 0;
                    const flush = (u8) => {
                        let bin = '';
                        for (let i = 0; i < u8.length; i += 0x8000)
                            bin += String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + 0x8000, u8.length)));
                        window.webkit.messageHandlers.sync.postMessage({kind: 'chunk', fid: fid, i: seq++, data: btoa(bin)});
                    };
                    while (true) {
                        const {done, value} = await reader.read();
                        if (done) break;
                        if (!value || !value.length) continue;
                        const merged = new Uint8Array(buf.length + value.length);
                        merged.set(buf, 0); merged.set(value, buf.length);
                        buf = merged;
                        while (buf.length >= CHUNK) { flush(buf.subarray(0, CHUNK)); buf = buf.slice(CHUNK); }
                    }
                    if (buf.length) flush(buf);
                    if (seq === 0) flush(new Uint8Array(0));   // 空文件也发一片，保持编号存在
                    window.webkit.messageHandlers.sync.postMessage({kind: 'done', fid: fid});
                } catch (e) {
                    window.webkit.messageHandlers.sync.postMessage({kind: 'fail', fid: fid, error: String(e)});
                }
            })();
            """
            wv.evaluateJavaScript(script, completionHandler: nil)
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
        if message.name == "login" {
            handleLoginMessage(kind: kind, body: body)
            return
        }
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

    /// 按扩展名缓存：同一门课里 180 个文件大多是 pdf/docx/pptx 几种，逐个文件问 LaunchServices 没必要
    private static var cache: [String: [AppOption]] = [:]
    /// 菜单里 16pt 的小图标，每个 App 只渲染一次（原图是 1024px，直接塞进菜单会留下大位图）
    private static var iconCache: [String: NSImage] = [:]

    /// 菜单里显示的 App 名：去掉 .app 后缀
    static func displayName(_ appURL: URL) -> String {
        var n = FileManager.default.displayName(atPath: appURL.path)
        if n.hasSuffix(".app") { n.removeLast(4) }
        return n
    }

    /// 菜单项图标：固定 32×32 位图（16pt @2x）。直接塞 1024px 原图会让菜单为每一项
    /// 各留一张大位图，实测光图标就多占 50MB。
    static func menuIcon(_ appURL: URL) -> NSImage {
        if let c = iconCache[appURL.path] { return c }
        let src = NSWorkspace.shared.icon(forFile: appURL.path)
        let px = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return src }
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 16, height: 16))
        img.addRepresentation(rep)
        iconCache[appURL.path] = img
        return img
    }

    /// 能打开该文件的 App：默认 App 置顶（标记 isDefault），其余按名称排序；同名只留一份
    static func apps(for fileURL: URL) -> [AppOption] {
        let key = fileURL.pathExtension.lowercased()
        if let c = cache[key] { return c }
        let ws = NSWorkspace.shared
        var seen = Set<String>()
        var out: [AppOption] = []
        if let d = ws.urlForApplication(toOpen: fileURL) {
            let n = displayName(d)
            seen.insert(n)
            out.append(AppOption(url: d, name: n, isDefault: true))
        }
        var rest: [AppOption] = []
        for u in ws.urlsForApplications(toOpen: fileURL) {
            let n = displayName(u)
            guard !seen.contains(n) else { continue }   // 同一 App 装了两份（/Applications 与 ~/Applications）只列一次
            seen.insert(n)
            rest.append(AppOption(url: u, name: n, isDefault: false))
        }
        rest.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        out.append(contentsOf: rest)
        cache[key] = out
        return out
    }

    static func open(_ fileURL: URL, with appURL: URL) {
        let appName = displayName(appURL)
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
    @MainActor static var isBusy = false

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

    /// 专用会话：请求间隔超时 15s / 资源总超时 60s（防连接挂起时永久等待）
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    /// 弹窗并强制置顶（LSUIElement / 前台无焦点场景下的可见性保障）
    @MainActor
    static func showAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
        showTopAlert(a)
    }

    static func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.message("无效的 API 地址")
        }
        var req = URLRequest(url: url)
        req.setValue("CanvasBar-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw UpdateError.message("GitHub 返回 HTTP \(code)（仓库 \(repo) 暂无 Release？）")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// 菜单「⬆️ 检查更新…」入口
    @MainActor
    static func checkFromMenu() {
        guard !isBusy else { return }
        isBusy = true
        let state = AppState.shared
        state.progress = "正在检查更新…"
        log("检查更新：用户触发（当前 v\(currentVersion)）")
        Task { @MainActor in
            do {
                let rel = try await fetchLatest()
                state.progress = ""
                if isNewer(rel.tag_name, than: currentVersion) {
                    log("检查更新：远端 \(rel.tag_name) → 有新版本，弹窗提示")
                    promptUpdate(rel)
                } else {
                    isBusy = false
                    log("检查更新：远端 \(rel.tag_name) → 已是最新")
                    let a = NSAlert()
                    a.messageText = "已是最新版本（v\(currentVersion)）"
                    var info = "GitHub 最新 Release：\(rel.tag_name)"
                    if let d = rel.published_at { info += "（\(d.prefix(10)) 发布）" }
                    a.informativeText = info
                    a.addButton(withTitle: "好")
                    _ = showAlert(a)
                    log("检查更新：已是最新提示已关闭")
                }
            } catch {
                isBusy = false
                state.progress = ""
                log("检查更新失败: \(error.localizedDescription)")
                let a = NSAlert()
                a.messageText = "检查更新失败"
                a.informativeText = "\(error.localizedDescription)\n可稍后重试，或直接打开 GitHub 发布页查看。"
                a.addButton(withTitle: "好")
                a.addButton(withTitle: "打开发布页")
                if showAlert(a) == .alertSecondButtonReturn,
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
        let r = showAlert(a)
        if r == .alertFirstButtonReturn {
            log("更新提示：用户选择「一键更新」")
            performUpdate(rel)
        } else if r == .alertSecondButtonReturn {
            isBusy = false
            log("更新提示：用户选择「查看 Release 页面」")
            if let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
        } else {
            isBusy = false
            log("更新提示：用户选择「稍后」")
        }
    }

    /// 一键更新：下载 → 解压校验 → 后台替换脚本 → 退出重启
    @MainActor
    static func performUpdate(_ rel: Release) {
        isBusy = true
        let state = AppState.shared
        let targetApp = Bundle.main.bundlePath
        let parentDir = (targetApp as NSString).deletingLastPathComponent
        log("一键更新：开始（target=\(targetApp)）")
        guard FileManager.default.isWritableFile(atPath: parentDir) else {
            isBusy = false
            log("一键更新：中止——目录不可写 \(parentDir)")
            fallbackToReleasePage(rel, why: "当前 App 所在目录不可写（\(parentDir)），无法自动更新。")
            return
        }
        guard let asset = rel.assets.first(where: { $0.name.hasSuffix("universal.zip") })
                ?? rel.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            isBusy = false
            log("一键更新：中止——Release 未附带 zip 资产")
            fallbackToReleasePage(rel, why: "该 Release 未附带 zip 安装包。")
            return
        }
        log("一键更新：选中资产 \(asset.name)")
        state.progress = "正在下载 \(asset.name) …"
        Task { @MainActor in
            do {
                let zip = try await download(asset)
                state.progress = "下载完成，正在解压与校验…"
                let staged = try stage(zip: zip, expectVersion: rel.tag_name)
                state.progress = "更新包就绪，正在重启替换…"
                try applyAndRelaunch(stagedApp: staged, targetApp: targetApp, zip: zip)
            } catch {
                isBusy = false
                state.progress = ""
                log("更新失败: \(error.localizedDescription)")
                let a = NSAlert()
                a.messageText = "更新失败"
                a.informativeText = "\(error.localizedDescription)\n已保留当前版本，可稍后重试。"
                a.addButton(withTitle: "好")
                _ = showAlert(a)
            }
        }
    }

    @MainActor
    static func fallbackToReleasePage(_ rel: Release, why: String) {
        let a = NSAlert()
        a.messageText = "无法自动更新"
        a.informativeText = "\(why)\n已为你打开 Release 页面，可手动下载安装。"
        a.addButton(withTitle: "好")
        _ = showAlert(a)
        if let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
    }

    static func download(_ asset: Release.Asset) async throws -> URL {
        guard let url = URL(string: asset.browser_download_url) else {
            throw UpdateError.message("无效的下载地址")
        }
        log("更新：开始下载 \(asset.name)")
        var req = URLRequest(url: url)
        req.setValue("CanvasBar-Updater", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await session.download(for: req)
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

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// 写替换脚本（等待本进程退出 → 换包 → 重启；失败自动回滚），随后本进程退出
    @MainActor
    static func applyAndRelaunch(stagedApp: URL, targetApp: String, zip: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let udir = supportDir.appendingPathComponent("update", isDirectory: true)
        let script = udir.appendingPathComponent("apply_update.sh")
        let oldBackup = udir.appendingPathComponent("CanvasBar-old.app").path
        let logPath = udir.appendingPathComponent("apply.log").path
        let stageDir = udir.appendingPathComponent("stage", isDirectory: true).path

        let qLog = shQuote(logPath)
        let qOld = shQuote(oldBackup)
        let qTarget = shQuote(targetApp)
        let qStaged = shQuote(stagedApp.path)
        let qStageDir = shQuote(stageDir)
        let qZip = shQuote(zip.path)

        let sh = """
        #!/bin/zsh
        exec >> \(qLog) 2>&1
        echo "[update] $(date '+%F %T') 等待旧实例退出（pid \(pid)）…"
        for i in {1..200}; do /bin/kill -0 \(pid) 2>/dev/null || break; sleep 0.3; done
        sleep 0.5
        if [ -d \(qOld) ]; then /usr/bin/trash \(qOld) >/dev/null 2>&1 || true; fi
        if /bin/mv \(qTarget) \(qOld); then
            if /usr/bin/ditto \(qStaged) \(qTarget); then
                /usr/bin/xattr -dr com.apple.quarantine \(qTarget) >/dev/null 2>&1 || true
                echo "[update] 替换完成，重启：\(targetApp)"
                /usr/bin/open \(qTarget)
                /usr/bin/trash \(qOld) >/dev/null 2>&1 || true
                /usr/bin/trash \(qStageDir) >/dev/null 2>&1 || true
                /usr/bin/trash \(qZip) >/dev/null 2>&1 || true
            else
                echo "[update] ditto 失败，回滚旧版本"
                /bin/mv \(qOld) \(qTarget)
                /usr/bin/open \(qTarget)
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

// MARK: - 菜单尺寸（v2.11）

/// 各级菜单统一宽度：文本可用 223pt，加菜单内边距后根菜单实测正好 300pt。
/// 菜单项标题超出可用宽度时按中段省略，避免长文件名把整级菜单一路撑宽。
enum MenuMetrics {
    /// 菜单项文本可用宽度（300pt 扣掉菜单左右内边距与图标位；实测 250 → 327pt）
    static let textWidth: CGFloat = 223

    static let font = NSFont.menuFont(ofSize: 0)

    static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// 超宽时保留头部 60% / 尾部 40%，中间以 … 省略（尾部保留扩展名等信息）
    static func fit(_ s: String) -> String {
        guard width(s) > textWidth else { return s }
        let chars = Array(s)
        var lo = 1, hi = max(1, chars.count - 1)
        var best = "…"
        while lo <= hi {
            let keep = (lo + hi) / 2
            let head = max(1, Int((Double(keep) * 0.6).rounded()))
            let tail = max(0, keep - head)
            let cand = String(chars.prefix(head)) + "…" + (tail > 0 ? String(chars.suffix(tail)) : "")
            if width(cand) <= textWidth {
                best = cand
                lo = keep + 1
            } else {
                hi = keep - 1
            }
        }
        return best
    }

    /// 下级菜单顶部：一级菜单放不下的完整标题在这里折行（按词断，CJK 无空格时按字断）
    static func wrap(_ s: String) -> [String] {
        let t = s.replacingOccurrences(of: "🆕 ", with: "🆕\u{00A0}")
        guard width(t) > textWidth else { return [t] }
        var lines: [String] = []
        var line = ""
        for w in t.split(whereSeparator: { $0 == " " || $0 == "　" }) {
            let word = String(w)
            let cand = line.isEmpty ? word : line + " " + word
            if width(cand) <= textWidth {
                line = cand
                continue
            }
            if !line.isEmpty {
                lines.append(line)
                line = ""
            }
            if width(word) <= textWidth {
                line = word
                continue
            }
            var chunk = ""
            for ch in word {
                if width(chunk + String(ch)) <= textWidth {
                    chunk.append(ch)
                } else {
                    lines.append(chunk)
                    chunk = String(ch)
                }
            }
            line = chunk
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [t] : lines
    }

    /// 该行标题在一级菜单里是否会被省略（是则下级菜单顶部补上完整标题）
    static func truncated(_ s: String) -> Bool { width(s) > textWidth }

    /// 文件行显示名（带 🆕 角标）
    @MainActor
    static func fileLabel(_ courseId: Int64, _ name: String) -> String {
        AppState.shared.isNewFile(courseId, name) ? "🆕 " + name : name
    }

    static func folderLabel(_ name: String) -> String { "📁 " + name }
}

// MARK: - 菜单 UI

/// 课程行标题（根菜单与省略映射共用，避免两处各写一份）
@MainActor
func courseMenuLabel(_ c: CachedCourse) -> String {
    let st = AppState.shared
    let n = st.newFiles[c.id]?.count ?? 0
    let off = st.syncDisabled.contains(c.id) ? "　⏸" : ""
    return n > 0 ? "📚  \(c.name)　🆕 \(n)\(off)" : "📚  \(c.name)\(off)"
}

/// 课程子菜单顶部：课程全名（含新内容数 / 停止同步标记），一级菜单放不下时才出现
@MainActor
func courseHeader(_ c: CachedCourse) -> String {
    let st = AppState.shared
    let n = st.newFiles[c.id]?.count ?? 0
    let off = st.syncDisabled.contains(c.id) ? "（已停止同步）" : ""
    return n > 0 ? "\(c.name)　🆕 \(n)\(off)" : "\(c.name)\(off)"
}

// MARK: - 菜单栏（原生 NSMenu，逐级按需展开）

/// 菜单项动作的轻量载体：菜单项自己当 target，闭包随项释放
final class ActionItem: NSMenuItem {
    var run: (() -> Void)?

    @objc func fire() { run?() }
}

/// 只有真正展开的那一级才会生成菜单项（根菜单约 40 项、一门课十来项、
/// 一个文件的「打开方式」也只在那一下才算）。
/// 旧版是 SwiftUI Menu 一次建整棵树：180 个文件 × 12 个 App ≈ 3 万个内部节点，常驻 150MB+。
final class LazyMenu: NSMenu, NSMenuDelegate {
    private var populate: ((NSMenu) -> Void)?

    init(title: String, populate: @escaping (NSMenu) -> Void) {
        self.populate = populate
        super.init(title: title)
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("unsupported") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate?(menu)
    }
}

@MainActor
final class MenuController: NSObject {
    static let shared = MenuController()

    private var statusItem: NSStatusItem?
    private var labelObserver: AnyCancellable?

    func install() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = si.button {
            b.image = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "CanvasBar")
            b.imagePosition = .imageLeading
            b.font = NSFont.menuBarFont(ofSize: 0)
        }
        si.menu = LazyMenu(title: "CanvasBar") { [weak self] m in self?.fillRoot(m) }
        statusItem = si
        updateLabel()
        // 仅订阅影响 DDL 剩余天数的字段，避免 progress 更新高频重算菜单栏标签
        let st = AppState.shared
        labelObserver = Publishers.CombineLatest3(st.$upcoming, st.$manualDdl, st.$ddlDone)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in MainActor.assumeIsolated { self?.updateLabel() } }
    }

    /// 状态栏标签：最近 DDL 剩余天数
    func updateLabel() {
        guard let b = statusItem?.button else { return }
        if let d = AppState.shared.nearestDays {
            b.title = d <= 0 ? "今天" : "\(d)d"
        } else {
            b.title = ""
        }
    }

    // MARK: 构造工具

    private func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let it = ActionItem(title: title, action: #selector(ActionItem.fire), keyEquivalent: "")
        it.target = it
        it.run = run
        return it
    }

    private func check(_ title: String, on: Bool, _ run: @escaping () -> Void) -> NSMenuItem {
        let it = action(title, run)
        it.state = on ? .on : .off
        return it
    }

    /// 下级菜单顶部的完整标题：一级菜单放不下的内容在这里折行显示
    private func header(_ m: NSMenu, _ text: String) {
        for line in MenuMetrics.wrap(text) { m.addItem(info(line)) }
    }

    private func submenuItem(_ title: String, build: @escaping (NSMenu) -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = LazyMenu(title: title, populate: build)
        return it
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: 根菜单

    private func fillRoot(_ m: NSMenu) {
        let st = AppState.shared
        m.addItem(info(MenuMetrics.fit("Canvas 课业同步 · \(st.lastSyncText)")))
        m.addItem(.separator())

        if st.upcomingSoon.isEmpty {
            m.addItem(info(MenuMetrics.fit("⏰ 暂无近期待办")))
        } else {
            m.addItem(info(MenuMetrics.fit("⏰ 最近 DDL（点开可标记已提交）")))
            for e in st.upcomingSoon.prefix(5) {
                let row = "📅  " + st.ddlText(for: e)
                m.addItem(submenuItem(MenuMetrics.fit(row)) { m2 in self.fillDdl(m2, e: e, row: row) })
            }
        }
        m.addItem(action(MenuMetrics.fit("➕ 添加 Deadline…（选课程与日期）")) { DdlUI.promptAdd() })
        if !st.ddlDone.isEmpty {
            m.addItem(action(MenuMetrics.fit("↩️ 恢复已忽略的 DDL（\(st.ddlDone.count)）")) { st.restoreDdlDone() })
        }

        m.addItem(.separator())

        for c in st.courses {
            let row = courseMenuLabel(c)
            m.addItem(submenuItem(MenuMetrics.fit(row)) { m2 in self.fillCourse(m2, c: c, row: row) })
        }

        if st.newTotal > 0 {
            m.addItem(action(MenuMetrics.fit("✅ 新内容全部标为已读（\(st.newTotal)）")) { st.clearAllNew() })
        }

        m.addItem(.separator())

        let sync = action(MenuMetrics.fit(st.isSyncing ? "⏳ 同步中…" : "🔄 立即同步")) {
            Task { await SyncEngine.shared.syncAll() }
        }
        sync.isEnabled = !st.isSyncing
        m.addItem(sync)

        m.addItem(submenuItem(MenuMetrics.fit("☑️ 同步范围（按课程勾选）")) { m2 in
            for c in st.courses {
                m2.addItem(self.check(MenuMetrics.fit(c.name), on: !st.syncDisabled.contains(c.id)) {
                    st.setSyncEnabled(c.id, !st.syncDisabled.contains(c.id))
                })
            }
        })

        m.addItem(check(MenuMetrics.fit("🎬 跳过视频（保留在线链接）"), on: st.skipVideos) {
            st.setSkipVideos(!st.skipVideos)
        })
        m.addItem(check(MenuMetrics.fit("📏 跳过 ≥\(bigFileLimitMB)MB 文件（保留在线链接）"), on: st.skipBig) {
            st.setSkipBig(!st.skipBig)
        })

        m.addItem(.separator())

        m.addItem(action(MenuMetrics.fit("🔑 登录 Canvas…")) { SyncEngine.shared.showLogin() })
        m.addItem(action(MenuMetrics.fit("🔑 设置 Canvas 登录账号…")) { LoginVaultUI.promptSave() })
        m.addItem(action(MenuMetrics.fit("📂 打开同步库（Canvas 同步）")) { self.openFolder(syncRoot) })
        m.addItem(action(MenuMetrics.fit("⚙️ 设置 Canvas 域名…（\(Cfg.host)）")) { ConfigUI.promptOrigin() })
        m.addItem(submenuItem(MenuMetrics.fit("⏱ 自动同步频率")) { m2 in
            let cur = Cfg.syncIntervalMinutes
            for preset in Cfg.syncIntervalPresets {
                m2.addItem(self.check(MenuMetrics.fit(preset.label), on: cur == preset.minutes) {
                    Cfg.save(syncIntervalMinutes: preset.minutes)
                    st.progress = "⏱ 同步频率已设为：\(preset.label)"
                    log("同步频率已改为 \(preset.minutes) 分钟")
                })
            }
        })
        m.addItem(action(MenuMetrics.fit("📄 查看日志")) { NSWorkspace.shared.open(logURL) })
        let updItem = action(MenuMetrics.fit(Updater.isBusy ? "⏳ 更新进行中…" : "⬆️ 检查更新…")) { Updater.checkFromMenu() }
        updItem.isEnabled = !Updater.isBusy
        m.addItem(updItem)

        m.addItem(check(MenuMetrics.fit("🚀 开机自动启动"), on: st.autoStartOn) {
            st.autoStartOn.toggle()
            AutoStart.set(st.autoStartOn)
        })

        if !st.progress.isEmpty {
            m.addItem(.separator())
            m.addItem(info(MenuMetrics.fit(st.progress)))
        }

        m.addItem(.separator())
        m.addItem(action(MenuMetrics.fit("退出 CanvasBar")) { NSApp.terminate(nil) })
    }

    // MARK: DDL 子菜单

    private func fillDdl(_ m: NSMenu, e: UpcomingEvent, row: String) {
        let st = AppState.shared
        if MenuMetrics.truncated(row) {
            header(m, st.ddlFullText(for: e))
            m.addItem(.separator())
        }
        if let s = e.url, !s.isEmpty, let u = URL(string: s) {
            m.addItem(action(MenuMetrics.fit("🌐 在 Canvas 打开")) { NSWorkspace.shared.open(u) })
        }
        m.addItem(action(MenuMetrics.fit("✅ 标记为已提交（不再提醒）")) { st.markDdlDone(e) })
        if st.isManualDdl(e) {
            m.addItem(.separator())
            m.addItem(action(MenuMetrics.fit("🗑 删除此 Deadline")) { st.removeManualDdl(e) })
        }
    }

    // MARK: 课程子菜单

    private func fillCourse(_ m: NSMenu, c: CachedCourse, row: String) {
        let st = AppState.shared
        Task { await st.refreshCourse(c) }
        if MenuMetrics.truncated(row) {
            header(m, courseHeader(c))
            m.addItem(.separator())
        }
        m.addItem(action(MenuMetrics.fit("🌐 在 Canvas 打开课程")) {
            if let u = URL(string: "\(Cfg.origin)/courses/\(c.id)") {
                NSWorkspace.shared.open(u)
                log("菜单打开 Canvas 课程页: \(c.name) → \(u.absoluteString)")
            }
        })
        m.addItem(action(MenuMetrics.fit("📂 打开课程文件夹")) {
            self.openFolder(c.url)
            st.clearNew(c.id)
        })
        if !st.syncDisabled.contains(c.id) {
            let it = action(MenuMetrics.fit("🔄 立即同步此课程")) {
                Task { await SyncEngine.shared.syncAll(only: [c.id]) }
            }
            it.isEnabled = !st.isSyncing
            m.addItem(it)
        }
        let extLinks = st.linksFor(c.id)
        if !extLinks.isEmpty {
            m.addItem(.separator())
            for l in extLinks {
                m.addItem(action(MenuMetrics.fit("🔗 \(l.title)")) {
                    if let u = URL(string: l.url) {
                        NSWorkspace.shared.open(u)
                        log("菜单打开外部链接: \(l.url)")
                    }
                })
            }
        }
        let nodes = st.menuNodes(for: c)
        if nodes.isEmpty {
            m.addItem(.separator())
            m.addItem(info(MenuMetrics.fit("（暂无同步文件）")))
        } else {
            m.addItem(.separator())
            addNodes(m, nodes, course: c)
        }
        m.addItem(.separator())
        if st.syncDisabled.contains(c.id) {
            m.addItem(action(MenuMetrics.fit("✅ 恢复同步该课程")) {
                st.setSyncEnabled(c.id, true)
                st.progress = "已恢复同步：\(c.name)"
                log("用户恢复课程同步: \(c.name) [\(c.id)]")
            })
        } else {
            m.addItem(action(MenuMetrics.fit("🚫 关闭该课程（停止同步）…")) { CoursesUI.confirmClose(c) })
        }
    }

    // MARK: 文件树（目录 → 子菜单，文件 → 操作子菜单）

    private func addNodes(_ m: NSMenu, _ nodes: [MenuNode], course: CachedCourse) {
        let st = AppState.shared
        for n in nodes {
            if n.isDir {
                let row = MenuMetrics.folderLabel(n.name)
                m.addItem(submenuItem(MenuMetrics.fit(row)) { m2 in
                    if MenuMetrics.truncated(row) {
                        self.header(m2, row)
                        m2.addItem(.separator())
                    }
                    self.addNodes(m2, n.children, course: course)
                    m2.addItem(.separator())
                    m2.addItem(self.action(MenuMetrics.fit("📍 在 Finder 中显示")) {
                        st.revealNode(course, n)
                    })
                })
            } else {
                let row = MenuMetrics.fileLabel(course.id, n.name)
                m.addItem(submenuItem(MenuMetrics.fit(row)) { m2 in
                    self.fillFile(m2, course: course, n: n, row: row)
                })
            }
        }
    }

    /// 文件级操作：打开（默认 App）/ 打开方式（进这一级才算 App 列表）/ 在 Finder 中显示
    private func fillFile(_ m: NSMenu, course: CachedCourse, n: MenuNode, row: String) {
        let st = AppState.shared
        if MenuMetrics.truncated(row) {
            header(m, row)
            m.addItem(.separator())
        }

        let fileURL: URL? = {
            guard let p = n.path, FileManager.default.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        }()

        if let fileURL {
            let apps = OpenWith.apps(for: fileURL)   // 惰性：只有展开这一级才查 LaunchServices
            let def = apps.first(where: { $0.isDefault }) ?? apps.first
            if let def {
                let it = action(MenuMetrics.fit("打开（\(def.name)）")) { st.openNode(course, n) }
                it.image = OpenWith.menuIcon(def.url)
                m.addItem(it)
            } else {
                m.addItem(action(MenuMetrics.fit("打开")) { st.openNode(course, n) })
            }
            let others = apps.filter { $0.url != def?.url }
            if !others.isEmpty {
                m.addItem(.separator())
                for a in others.prefix(12) {
                    let it = action(MenuMetrics.fit(a.name)) { OpenWith.open(fileURL, with: a.url) }
                    it.image = OpenWith.menuIcon(a.url)
                    m.addItem(it)
                }
            }
            m.addItem(action(MenuMetrics.fit("其他…（选择应用）")) { OpenWith.chooseAppAndOpen(fileURL) })
        } else {
            // 路径失效时可点击触发按文件名自愈打开
            m.addItem(action(MenuMetrics.fit("打开（尝试查找已移动的文件）")) { st.openNode(course, n) })
        }

        m.addItem(.separator())
        m.addItem(action(MenuMetrics.fit("📍 在 Finder 中显示")) { st.revealNode(course, n) })
    }
}

enum CoursesUI {
    @MainActor
    static func confirmClose(_ c: CachedCourse) {
        let a = NSAlert()
        a.messageText = "关闭「\(c.name)」的同步？"
        a.informativeText = "已同步的文件会原样保留在课程文件夹中（子菜单里仍可打开），但从现在起不再检查、下载该课程的新内容。可随时在子菜单里恢复。"
        a.addButton(withTitle: "关闭同步")
        a.addButton(withTitle: "取消")
        guard showTopAlert(a) == .alertFirstButtonReturn else { return }
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
        guard showTopAlert(alert) == .alertFirstButtonReturn else { return }
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
            showTopAlert(a)
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
        guard showTopAlert(alert) == .alertFirstButtonReturn else { return }

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

// MARK: - App 入口（纯 AppKit，零 SwiftUI 壳）

@main
enum CanvasBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

// MARK: - 同一环境只留一份安装（v2.13）

/// 同一台机器只允许存在一份 CanvasBar.app（只看标准安装目录，开发用的 .build 副本不参与），
/// 扫到第二份就在启动时提示并（默认）移入废纸篓；选「保留」会把 path|版本 记进
/// version-guard.json，之后不再重复问。移入废纸篓走 FileManager.trashItem，可撤销。
@MainActor
enum SingleVersion {
    /// 视为「已安装」的目录
    private static var installDirs: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
         URL(fileURLWithPath: "/Users/Shared", isDirectory: true)]
    }

    private static var recordURL: URL { supportDir.appendingPathComponent("version-guard.json") }

    private struct Copy {
        let url: URL
        let version: String
        var key: String { url.path + "|" + version }
    }

    private static func copies() -> [Copy] {
        installDirs.compactMap { dir in
            let u = dir.appendingPathComponent("CanvasBar.app", isDirectory: true).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: u.path) else { return nil }
            let v = Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return Copy(url: u, version: v ?? "?")
        }
    }

    private static func ignored() -> Set<String> {
        guard let d = try? Data(contentsOf: recordURL),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }

    private static func remember(_ keys: [String]) {
        let all = Array(ignored().union(keys))
        guard let d = try? JSONEncoder().encode(all) else { return }
        try? d.write(to: recordURL, options: .atomic)
    }

    /// 启动时调用。只有当前运行的就是标准安装副本时才动手，免得开发构建把装好的那份删掉。
    static func enforce() {
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let all = copies()
        guard all.contains(where: { $0.url.path == me.path }) else {
            log("版本守卫：当前副本不在标准安装目录（\(me.path)），跳过")
            return
        }
        let others = all.filter { $0.url.path != me.path }
        guard !others.isEmpty else {
            log("版本守卫：安装目录只有一份（v\(Updater.currentVersion)）")
            return
        }
        let skip = ignored()
        let todo = others.filter { !skip.contains($0.key) }
        guard !todo.isEmpty else {
            log("版本守卫：另有 \(others.count) 份副本，均已被用户标记保留")
            return
        }

        let list = todo.map { "· \($0.url.path)（v\($0.version)）" }.joined(separator: "\n")
        log("版本守卫：发现 \(todo.count) 份多余安装 → \(list.replacingOccurrences(of: "\n", with: " / "))")

        // 测试钩子：只记日志，不弹窗
        if ProcessInfo.processInfo.environment["CANVASBAR_GUARD_DRYRUN"] == "1" {
            log("版本守卫：DRYRUN，跳过弹窗")
            return
        }

        let a = NSAlert()
        a.messageText = "同一环境只保留一份 CanvasBar"
        a.informativeText = "检测到另外 \(todo.count) 份安装（当前运行 \(me.path) · v\(Updater.currentVersion)）：\n\(list)\n\n移入废纸篓会保留可撤销的副本，不影响当前这份。"
        a.addButton(withTitle: "移入废纸篓")
        a.addButton(withTitle: "保留，不再提示")
        let choice = showTopAlert(a)

        guard choice == .alertFirstButtonReturn else {
            remember(todo.map(\.key))
            log("版本守卫：用户选择保留 \(todo.map(\.url.path).joined(separator: ", "))")
            return
        }
        for c in todo {
            do {
                try FileManager.default.trashItem(at: c.url, resultingItemURL: nil)
                log("版本守卫：已移入废纸篓 \(c.url.path)（v\(c.version)）")
            } catch {
                log("版本守卫：移入废纸篓失败 \(c.url.path) — \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 菜单栏：原生 NSStatusItem + 逐级按需展开的 NSMenu
        MenuController.shared.install()
        // 缓存封顶：默认 URLCache 内存上限偏高，大文件下载会一路把内存顶上去
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
        trimLogIfNeeded()
        // v2.6：应用图标（取 bundle 内 AppIcon.icns；对话框等系统界面使用）
        if let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let ic = NSImage(contentsOf: u) {
            NSApp.applicationIconImage = ic
        }
        Cfg.load()
        AutoStart.syncPathIfEnabled()
        AppState.shared.autoStartOn = AutoStart.isEnabled
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        log("CanvasBar v\(Updater.currentVersion) 启动 | canvas=\(Cfg.origin) | 同步周期=\(Cfg.syncIntervalMinutes)m | 库=\(syncRoot.path) | macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        SingleVersion.enforce()   // 同一环境只留一份安装（多余副本提示移入废纸篓）
        AppState.shared.reloadManifest()
        let mi = AppState.shared.manifest
        log("菜单文件索引: \(mi.count) 门课 / \(mi.values.reduce(0) { $0 + $1.count }) 个文件")

        Task { @MainActor in
            AppState.shared.consumeAddDdlHook()
            await AppState.shared.refreshLibrary(force: true)
            let engine = SyncEngine.shared
            // 优先走原生 URLSession 轻量验会话（零 WebKit 页面内存）；失败再走 checkSession 静默重登
            var loggedIn = await engine.fetchSelfViaURLSession()
            if !loggedIn { loggedIn = (try? await engine.checkSession(force: false)) == true }
            if loggedIn {
                let interval = TimeInterval(Cfg.syncIntervalMinutes * 60)
                let due = AppState.shared.lastSync.map { Date().timeIntervalSince($0) > interval } ?? true
                let forced = consumeSyncRequest()
                if due || forced {
                    await engine.syncAll()          // 同步收尾自己会 releasePage
                } else {
                    engine.releasePage()            // 只验会话不同步 → 立刻卸页面，别留一屏 SPA 常驻
                }
            } else {
                engine.releasePage()                // 验不过就把 ADFS 页卸掉
                if AppState.shared.lastSync == nil {
                    engine.state.progress = "首次使用：请登录 Canvas"
                    engine.showLogin()
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in
                let state = AppState.shared
                MenuController.shared.updateLabel()   // 跨零点实时刷新状态栏剩余天数
                state.consumeAddDdlHook()
                // 平时打开课程子菜单会按单课惰性刷新；全库兜底扫描仅每 2 小时跑一次
                let libStale = state.libLastRefresh.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? true
                if libStale { await state.refreshLibrary() }
                guard !state.isSyncing else { return }
                await SyncEngine.shared.keepAlive()   // 30 分钟心跳：原生请求续期 / 静默重登（不弹窗）
                let interval = TimeInterval(Cfg.syncIntervalMinutes * 60)
                let due = state.lastSync.map { Date().timeIntervalSince($0) > interval } ?? true
                let forced = consumeSyncRequest()
                guard due || forced else { return }
                await SyncEngine.shared.syncAll()   // syncAll 内部验会话并处理未登录，省一次整页加载
            }
        }
    }
}

// MARK: - 登录凭据（Keychain）

/// macOS 的 WKWebView 拿不到系统密码自动填充：Safari 那套是浏览器自带的，
/// 第三方 app 要接得靠 associated domains + 域名方放 apple-app-site-association，
/// polyu.edu.hk 不在我们控制范围内。所以走自建：凭据存钥匙串，登录页注入一个填充按钮。
struct VaultCredential {
    let user: String
    let password: String
}

enum LoginVault {
    private static let service = "local.chester.canvasbar.canvas"

    // SecItemCopyMatching 在授权弹窗上会一直阻塞；而登录页每完成一次加载就调一次
    // autoFillLogin（SAML 递交页循环时几秒一次）。不收敛的话每几秒弹一个新窗，
    // 前一个窗的输入焦点被顶掉，密码框就成了「打不进字」。
    // 所以：一次启动只真正读一次，弹窗未答完不再叠加新请求，读完（成功/失败）即定型。
    private static var cache: VaultCredential?
    private static var didAttempt = false
    private static var loading = false
    private static var waiters: [(VaultCredential?) -> Void] = []
    private static var missingNoticeShown = false

    /// 异步读取。必须异步：钥匙串弹窗出现期间主线程会一直卡在这一个调用里。
    static func load(_ done: @escaping (VaultCredential?) -> Void) {
        if !Thread.isMainThread { DispatchQueue.main.async { load(done) }; return }
        if let c = cache { done(c); return }
        if didAttempt { done(nil); return }
        if loading { waiters.append(done); return }
        loading = true
        waiters.append(done)
        DispatchQueue.global(qos: .userInitiated).async {
            log("钥匙串读取: 开始（首次会弹授权窗，答完前不再重复请求）")
            let v = readKeychain()
            DispatchQueue.main.async {
                loading = false
                didAttempt = true
                cache = v
                log("钥匙串读取: 结束（\(v == nil ? "无凭据" : "已取到")）")
                let ws = waiters
                waiters = []
                ws.forEach { $0(v) }
            }
        }
    }

    /// 只取内存里的值，不触发弹窗（菜单设置面板预填用）
    static var cached: VaultCredential? { cache }

    /// 读不到时只提示一次，避免每次页面加载都写一行日志
    static func takeMissingNotice() -> Bool {
        if missingNoticeShown { return false }
        missingNoticeShown = true
        return true
    }

    static func save(user: String, password: String) {
        guard let data = password.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccount as String] = user
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "CanvasBar · Canvas 登录"
        SecItemAdd(add as CFDictionary, nil)
        cache = VaultCredential(user: user, password: password)
        didAttempt = true
        missingNoticeShown = false
    }

    private static func readKeychain() -> VaultCredential? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? [String: Any],
              let raw = d[kSecValueData as String] as? Data,
              let pass = String(data: raw, encoding: .utf8) else { return nil }
        return VaultCredential(user: (d[kSecAttrAccount as String] as? String) ?? "", password: pass)
    }

    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(q as CFDictionary)
        cache = nil
        didAttempt = true
    }
}

// MARK: - 账号设置面板

enum LoginVaultUI {
    @MainActor
    static func promptSave() {
        let a = NSAlert()
        a.messageText = "设置 Canvas 登录账号"
        a.informativeText = "存进 macOS 钥匙串（仅本机）。之后打开登录窗会自动填入账号密码。"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "删除已保存")
        a.addButton(withTitle: "取消")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        let user = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        user.placeholderString = "账号（例：25123456d@connect.polyu.hk）"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        pass.placeholderString = "密码"
        if let v = LoginVault.cached { user.stringValue = v.user }
        box.addSubview(user)
        box.addSubview(pass)
        a.accessoryView = box
        a.window.initialFirstResponder = user

        switch showTopAlert(a) {
        case .alertFirstButtonReturn:
            let u = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !u.isEmpty, !pass.stringValue.isEmpty else {
                log("设置登录账号: 账号或密码为空，未保存")
                return
            }
            LoginVault.save(user: u, password: pass.stringValue)
            log("设置登录账号: 已存入钥匙串（\(u)）")
        case .alertSecondButtonReturn:
            LoginVault.clear()
            log("设置登录账号: 已从钥匙串删除")
        default:
            break
        }
    }
}
