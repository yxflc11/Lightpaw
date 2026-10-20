import AppKit
import Foundation
import Darwin

let GiB = Double(1 << 30)
enum Pressure: Int, Codable {
    case normal = 1, warning = 2, critical = 4, unknown = -1
    static func classify(_ raw: Int32, error: Int32) -> Pressure {
        error == 0 ? (Pressure(rawValue: Int(raw)) ?? .unknown) : .unknown
    }
    var title: String { switch self { case .normal:return "正常";case .warning:return "警告";case .critical:return "严重";case .unknown:return "未知" } }
    var color: NSColor { switch self { case .normal:return .systemGreen;case .warning:return .systemOrange;case .critical:return .systemRed;case .unknown:return .secondaryLabelColor } }
}
struct Identity: Hashable { let pid: Int32;let seconds: UInt64;let micros: UInt64 }
struct Proc {
    let id: Identity;let parent: Int32;let name: String;let path: String
}
struct ProcessReading: Codable { let pid:Int32;let basename:String;let category:String;let footprintBytes:UInt64?;let error:Int32 }
struct Changes: Codable { var started:[Int32] = [];var exited:[Int32] = [];var changed:Bool { !started.isEmpty || !exited.isEmpty } }
struct Tracker {
    var previous:Set<Identity>?
    mutating func update(_ current:Set<Identity>?) -> Changes {
        guard let current else { return Changes() }
        defer { previous=current }
        guard let previous else { return Changes() }
        return Changes(started:current.subtracting(previous).map(\.pid).sorted(),exited:previous.subtracting(current).map(\.pid).sorted())
    }
}
struct Reading: Codable {
    let timestamp:String
    let totalFootprintBytes:UInt64?
    let observedFootprintBytes:UInt64
    let complete:Bool
    let pressure:Pressure
    let pressureRaw:Int32?
    let pressureError:Int32
    let swapUsedBytes:UInt64?
    let swapTotalBytes:UInt64?
    let swapError:Int32
    let processCount:Int
    let processReadFailures:Int
    let discoverySkipped:Int
    let discoveryError:Int32
    let roots:[Int32]
    let rootChanges:Changes
    let rendererChanges:Changes
    let processes:[ProcessReading]
    let consecutiveHighSamples:Int
    let suggestReduceParallelism:Bool
}
struct Streak {
    var count=0
    mutating func update(pressure:Pressure,total:UInt64?) -> Bool {
        let high=pressure == .warning || pressure == .critical || (total.map { Double($0)>=8*GiB } ?? false)
        count=high ? min(count+1,999999) : 0
        return count>=3
    }
}
func nowString() -> String { ISO8601DateFormatter().string(from:Date()) }
func listProcesses() -> (items:[Proc],skipped:Int,error:Int32) {
    var pointer:UnsafeMutablePointer<CWMProcess>?;var count:Int32=0;var skipped:Int32=0
    let error=cwm_list(&pointer,&count,&skipped)
    guard error==0,let pointer else { return ([],Int(skipped),error == 0 ? EIO:error) }
    defer { cwm_free(pointer) }
    var result:[Proc]=[];result.reserveCapacity(Int(count))
    for i in 0..<Int(count) {
        let p=pointer.advanced(by:i);let v=p.pointee
        let path=String(cString:cwm_path(p));let fallback=String(cString:cwm_name(p))
        let name=path.isEmpty ? fallback : URL(fileURLWithPath:path).lastPathComponent
        result.append(Proc(id:Identity(pid:v.pid,seconds:v.seconds,micros:v.micros),parent:v.ppid,name:String(name.prefix(120)),path:path))
    }
    return (result,Int(skipped),0)
}
func targetExecutables() -> Set<String> {
    var result=Set<String>()
    for path in ["/Applications/ChatGPT.app","/Applications/Codex.app","/Codex.app"] {
        if let bundle=Bundle(path:path),bundle.bundleIdentifier == "com.openai.codex",let url=bundle.executableURL {
            result.insert(url.resolvingSymlinksInPath().path)
        }
    }
    return result
}
func descendants(_ all:[Proc],roots:Set<Identity>) -> [Proc] {
    var selected=Set(roots.map(\.pid));var changed=true
    while changed {
        changed=false
        for p in all where selected.contains(p.parent) && !selected.contains(p.id.pid) {
            selected.insert(p.id.pid);changed=true
        }
    }
    return all.filter { selected.contains($0.id.pid) }
}
func isEngine(_ p:Proc) -> Bool { ["codex","codex-app-server","app-server"].contains(p.name.lowercased()) }
func category(_ p:Proc,roots:Set<Identity>,lookup:[Int32:Proc]) -> String {
    if roots.contains(p.id) { return "主程序" }
    if p.name.lowercased().contains("renderer") { return "Renderer" }
    if p.name == "node" { return "Node 工具" }
    if isEngine(p) {
        var parent=p.parent;var seen=Set<Int32>()
        while let ancestor=lookup[parent],seen.insert(parent).inserted {
            if isEngine(ancestor) { return "子任务进程" }
            parent=ancestor.parent
        }
        return "任务引擎"
    }
    return "工具 / 辅助"
}
final class Sampler {
    var rootsTracker=Tracker();var rendererTracker=Tracker();var streak=Streak()
    func sample() -> Reading {
        let snapshot=listProcesses();let targets=targetExecutables()
        let rootRecords=snapshot.items.filter { targets.contains($0.path) }
        let roots=Set(rootRecords.map(\.id));let selected=descendants(snapshot.items,roots:roots)
        let lookup=Dictionary(uniqueKeysWithValues:snapshot.items.map { ($0.id.pid,$0) })
        var readings:[ProcessReading]=[];var observed:UInt64=0;var failures=0
        for p in selected {
            var bytes:UInt64=0
            let error=cwm_footprint(p.id.pid,p.id.seconds,p.id.micros,&bytes)
            if error==0 { observed += bytes } else { failures += 1 }
            readings.append(ProcessReading(pid:p.id.pid,basename:p.name,category:category(p,roots:roots,lookup:lookup),footprintBytes:error==0 ? bytes:nil,error:error))
        }
        // Recheck root identity after reading all children; PID reuse never becomes a valid total.
        let rootStable=rootRecords.allSatisfy { cwm_identity($0.id.pid,$0.id.seconds,$0.id.micros)==0 }
        let discoveryAmbiguous=roots.isEmpty && snapshot.skipped>0
        let complete=snapshot.error==0 && !discoveryAmbiguous && rootStable && failures==0
        let total:UInt64?=complete ? observed:nil
        var raw:Int32 = -1;let pressureError=cwm_pressure(&raw)
        let pressure=Pressure.classify(raw,error:pressureError)
        var swapUsed:UInt64=0;var swapTotal:UInt64=0;let swapError=cwm_swap(&swapUsed,&swapTotal)
        let rendererIDs=Set(selected.filter { category($0,roots:roots,lookup:lookup)=="Renderer" }.map(\.id))
        let identityReliable=snapshot.error==0 && !discoveryAmbiguous && rootStable
        let rootChange=rootsTracker.update(identityReliable ? roots:nil)
        let rendererChange=rendererTracker.update(identityReliable ? rendererIDs:nil)
        let suggest=streak.update(pressure:pressure,total:total)
        return Reading(timestamp:nowString(),totalFootprintBytes:total,observedFootprintBytes:observed,complete:complete,
                       pressure:pressure,pressureRaw:pressureError==0 ? raw:nil,pressureError:pressureError,
                       swapUsedBytes:swapError==0 ? swapUsed:nil,swapTotalBytes:swapError==0 ? swapTotal:nil,swapError:swapError,
                       processCount:selected.count,processReadFailures:failures,discoverySkipped:snapshot.skipped,discoveryError:snapshot.error,
                       roots:roots.map(\.pid).sorted(),rootChanges:rootChange,rendererChanges:rendererChange,processes:readings,
                       consecutiveHighSamples:streak.count,suggestReduceParallelism:suggest)
    }
}

// Log schema is constructed explicitly: never serialize process paths, argv, environment, or UI/error prose.
func logRecord(_ r:Reading) throws -> Data {
    let procs:[[String:Any]]=r.processes.map { ["pid":$0.pid,"basename":$0.basename,"footprint_bytes":$0.footprintBytes.map { $0 as Any } ?? NSNull()] }
    let obj:[String:Any]=["time":r.timestamp,"total_footprint_bytes":r.totalFootprintBytes.map { $0 as Any } ?? NSNull(),
                         "observed_footprint_bytes":r.observedFootprintBytes,"process_count":r.processCount,"read_failure_count":r.processReadFailures,
                         "discovery_skipped_count":r.discoverySkipped,"pressure_level":r.pressureRaw.map { $0 as Any } ?? NSNull(),
                         "swap_used_bytes":r.swapUsedBytes.map { $0 as Any } ?? NSNull(),"swap_total_bytes":r.swapTotalBytes.map { $0 as Any } ?? NSNull(),
                         "root_started_pids":r.rootChanges.started,"root_exited_pids":r.rootChanges.exited,
                         "renderer_started_pids":r.rendererChanges.started,"renderer_exited_pids":r.rendererChanges.exited,"processes":procs]
    var data=try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]);data.append(10);return data
}
struct LogError:Error { let message:String }
final class LogStore {
    let directory:URL;let maxBytes:UInt64;let calendar=Calendar(identifier:.gregorian)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    init(directory:URL,maxBytes:UInt64=20*1024*1024) throws {
        self.directory=directory;self.maxBytes=maxBytes
        let fm=FileManager.default
        if !fm.fileExists(atPath:directory.path) { try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        let attrs=try fm.attributesOfItem(atPath:directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,(attrs[.ownerAccountID] as? NSNumber)?.uint32Value==getuid() else { throw LogError(message:"日志目录类型或所有者异常") }
        guard chmod(directory.path,0o700)==0 else { throw LogError(message:"无法设置日志目录权限") }
    }
    func filename(_ date:Date) -> String { dateFormatter.string(from:date)+".jsonl" }
    func files() throws -> [(URL,UInt64)] {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).compactMap { url in
            guard url.lastPathComponent.range(of:#"^\d{4}-\d{2}-\d{2}\.jsonl$"#,options:.regularExpression) != nil else { return nil }
            let a=try FileManager.default.attributesOfItem(atPath:url.path)
            guard a[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (url,(a[.size] as? NSNumber)?.uint64Value ?? 0)
        }.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }
    func append(_ data:Data,at date:Date=Date()) throws {
        guard UInt64(data.count)<maxBytes else { throw LogError(message:"单条日志超出容量限制") }
        let current=directory.appendingPathComponent(filename(date))
        let cutoff=filename(calendar.date(byAdding:.day,value:-6,to:calendar.startOfDay(for:date))!)
        for (url,_) in try files() where url.lastPathComponent<cutoff { try FileManager.default.removeItem(at:url) }
        var entries=try files();var total=entries.reduce(UInt64(0)) { $0+$1.1 }
        while total+UInt64(data.count)>maxBytes,let index=entries.firstIndex(where:{$0.0 != current}) {
            let old=entries.remove(at:index)
            try FileManager.default.removeItem(at:old.0);total-=old.1
        }
        let fd=open(current.path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw LogError(message:"无法打开日志文件") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        guard fchmod(fd,0o600)==0 else { throw LogError(message:"无法设置日志文件权限") }
        if total+UInt64(data.count)>maxBytes {
            let size=try handle.seekToEnd();let keep=min(size,min(maxBytes-UInt64(data.count),min(maxBytes/2,1024*1024)))
            try handle.seek(toOffset:size-keep)
            var tail=try handle.read(upToCount:Int(keep)) ?? Data()
            if let newline=tail.firstIndex(of:10) { tail=tail.suffix(from:tail.index(after:newline)) } else { tail=Data() }
            try handle.truncate(atOffset:0);try handle.seek(toOffset:0);try handle.write(contentsOf:tail)
        }
        _=try handle.seekToEnd();try handle.write(contentsOf:data);try handle.close()
    }
}

func monitorSelfTest() throws {
    func check(_ condition:Bool,_ message:String) throws { if !condition { throw LogError(message:message) } }
    try check(Pressure.classify(1,error:0) == .normal && Pressure.classify(2,error:0) == .warning && Pressure.classify(4,error:0) == .critical,"压力映射失败")
    try check(Pressure.classify(0,error:0) == .unknown && Pressure.classify(1,error:EACCES) == .unknown,"读取失败被误判正常")
    var tracker=Tracker();let a=Identity(pid:20,seconds:1,micros:0),b=Identity(pid:20,seconds:2,micros:0)
    try check(!tracker.update([a]).changed,"首样本误报退出")
    try check(!tracker.update(nil).changed,"失败样本误报退出")
    let delta=tracker.update([b]);try check(delta.started==[20] && delta.exited==[20],"PID复用未识别")
    var streak=Streak();try check(!streak.update(pressure:.warning,total:0) && !streak.update(pressure:.warning,total:0) && streak.update(pressure:.warning,total:0),"连续三次规则失败")
    try check(!streak.update(pressure:.unknown,total:nil),"未知值未中断连续告警")
    let actual=listProcesses();try check(actual.error==0,"真实libproc列表读取失败 errno=\(actual.error)")
    guard let me=actual.items.first(where:{$0.id.pid==getpid()}) else { throw LogError(message:"无法读取自身进程") }
    var bytes:UInt64=0
    try check(cwm_footprint(me.id.pid,me.id.seconds,me.id.micros,&bytes)==0 && bytes>0,"真实自身phys_footprint读取失败")
    try check(cwm_footprint(me.id.pid,me.id.seconds+1,me.id.micros,&bytes)==EAGAIN,"身份不符未拒绝")
    // Actual filesystem exercise, restricted to the requested project working directory.
    let dir=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/self-test-"+UUID().uuidString)
    let store=try LogStore(directory:dir,maxBytes:1024);defer { try? FileManager.default.removeItem(at:dir) }
    let today=Date();let old=Calendar.current.date(byAdding:.day,value:-8,to:today)!
    try store.append(Data(repeating:65,count:700)+Data([10]),at:old)
    for _ in 0..<8 { try store.append(Data(repeating:66,count:300)+Data([10]),at:today) }
    let files=try store.files();try check(files.count==1 && files.reduce(0,{$0+$1.1})<=1024,"日志天数/总量上限失败")
    let attrs=try FileManager.default.attributesOfItem(atPath:dir.path)
    try check((attrs[.posixPermissions] as? NSNumber)?.intValue==0o700,"日志目录权限失败")
    print("PASS: pressure/error classification, root/renderer identity tracking and PID reuse, consecutive threshold, live libproc footprint, real log age/size retention and permissions.")
}
