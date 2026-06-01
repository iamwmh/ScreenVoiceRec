//
//  ScreenRecorderViewModel.swift
//  ScreenVoiceRec
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case window
    case display
    /// 内置 / 外接音频输入（麦克风、耳机麦、3.5 mm 线路输入等）。
    case headphoneJack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return L10n.tr("capture.source.window")
        case .display: return L10n.tr("capture.source.display")
        case .headphoneJack: return L10n.tr("capture.source.headphone")
        }
    }
}

@MainActor
final class ScreenRecorderViewModel: ObservableObject {
    private static let lastRecordingPathKey = "lastRecordingPath"

    @Published var sourceKind: CaptureSourceKind = .display
    @Published var windows: [SCWindow] = []
    @Published var displays: [SCDisplay] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedDisplayID: CGDirectDisplayID?
    /// 默认 AAC：与 ScreenCaptureKit 实时音频更匹配；若需未压缩可选手动选 WAV。
    @Published var exportFormat: AudioExportFormat = .aacM4A

    /// 最近一次成功录音在应用沙盒内的文件 URL（可直接读写，无需安全作用域）。
    @Published private(set) var lastRecordingURL: URL?

    @Published private(set) var phase: RecordingPhase = .idle
    @Published var statusMessage: String = L10n.tr("status.choose_source")

    @Published var playbackURL: URL?
    @Published private(set) var isPlaying: Bool = false
    /// 已通过 `preparePlayer` 载入 `AVPlayer`（可暂停 / 停止）。
    @Published private(set) var isPlaybackReady: Bool = false

    @Published private(set) var recordingElapsed: TimeInterval = 0
    /// 0...1，录音时由引擎估算的输入音量（已平滑），用于电平条。
    @Published private(set) var recordingLevel: Float = 0
    @Published var playbackCurrentTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published var isPlaybackScrubbing: Bool = false

    /// 正在刷新列表或启动采集（避免重复点「开始录音」；此时尚未进入录音态）。
    @Published private(set) var isPreparingRecording: Bool = false

    /// 已收到首帧系统音频并完成 `AVAssetWriter` 会话开始（计时器可能已在走，但此前文件可能尚未真正写入）。
    @Published private(set) var hasAudioSessionStarted: Bool = false

    /// 录音文件保存目录（应用容器内，固定路径）。
    @Published private(set) var recordingsFolderSummary: String = ""

    private let engine = ScreenAudioCaptureEngine()
    private let micEngine = HeadphoneInputCaptureEngine()
    private var player: AVPlayer?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackTimeObserver: Any?
    private var recordingTimer: Timer?
    /// 仅用于「选择文件…」打开的沙盒外音频；应用容器内录音不需要。
    private var activeSecurityScopedURL: URL?
    private var playerItemStatusObserver: NSKeyValueObservation?
    /// 当前 `AVPlayer` 已对应的文件 URL（避免重复 `preparePlayer`）。
    private var preparedPlaybackURL: URL?

    init() {
        engine.onError = { [weak self] err in
            Task { @MainActor in
                self?.handleEngineError(err)
            }
        }
        engine.onRecordingSessionStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasAudioSessionStarted = true
                if self.phase == .recording {
                    self.statusMessage = L10n.tr("status.recording")
                }
            }
        }
        engine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                guard self.phase == .recording || self.phase == .paused else { return }
                let s = self.recordingLevel * 0.55 + level * 0.45
                self.recordingLevel = min(1, max(0, s))
            }
        }
        engine.onStopped = { [weak self] url in
            Task { @MainActor in
                self?.finalizeRecordingStopped(url: url)
            }
        }
        micEngine.onError = { [weak self] err in
            Task { @MainActor in
                self?.handleEngineError(err)
            }
        }
        micEngine.onRecordingSessionStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hasAudioSessionStarted = true
                if self.phase == .recording {
                    self.statusMessage = L10n.tr("status.recording")
                }
            }
        }
        micEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                guard self.phase == .recording || self.phase == .paused else { return }
                let s = self.recordingLevel * 0.55 + level * 0.45
                self.recordingLevel = min(1, max(0, s))
            }
        }
        micEngine.onStopped = { [weak self] url in
            Task { @MainActor in
                self?.finalizeRecordingStopped(url: url)
            }
        }
        refreshRecordingsFolderSummary()
        loadLastRecordingPathIfPossible()
        Task { await refreshShareableContent() }
    }

    private func finalizeRecordingStopped(url: URL) {
        stopRecordingTimer()
        recordingElapsed = 0
        recordingLevel = 0
        hasAudioSessionStarted = false
        phase = .idle
        lastRecordingURL = url
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            statusMessage = L10n.tr("status.stopped_missing", path)
            return
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value, size == 0 {
            statusMessage = L10n.tr("status.stopped_zero")
            return
        }
        UserDefaults.standard.set(path, forKey: Self.lastRecordingPathKey)
        playbackURL = url
        preparePlayer(url: url)
        statusMessage = L10n.tr("status.saved", path)
    }

    private func refreshRecordingsFolderSummary() {
        if let dir = try? Self.ensureRecordingsDirectory() {
            recordingsFolderSummary = L10n.tr("recordings.folder.summary", dir.path)
        } else {
            recordingsFolderSummary = L10n.tr("recordings.folder.error")
        }
    }

    private static func ensureRecordingsDirectory() throws -> URL {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            struct AppSupportError: Error {}
            throw AppSupportError()
        }
        let bid = Bundle.main.bundleIdentifier ?? "ScreenVoiceRec"
        let dir = appSupport
            .appendingPathComponent(bid, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isAppRecordingFile(_ url: URL) -> Bool {
        guard let dir = try? Self.ensureRecordingsDirectory() else { return false }
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(d + "/") || p == d
    }

    private func loadLastRecordingPathIfPossible() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastRecordingPathKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            UserDefaults.standard.removeObject(forKey: Self.lastRecordingPathKey)
            return
        }
        lastRecordingURL = url
        if playbackURL == nil {
            playbackURL = url
        }
        statusMessage = L10n.tr("status.restored", path)
    }

    @discardableResult
    private func replaceSecurityScopedAccess(with newURL: URL?) -> Bool {
        if let u = activeSecurityScopedURL {
            u.stopAccessingSecurityScopedResource()
            activeSecurityScopedURL = nil
        }
        guard let newURL else { return true }
        guard newURL.startAccessingSecurityScopedResource() else {
            statusMessage = L10n.tr("status.security_scope")
            return false
        }
        activeSecurityScopedURL = newURL
        return true
    }

    private func hasSecurityScopeForSameFile(as url: URL) -> Bool {
        guard let active = activeSecurityScopedURL else { return false }
        return active.standardizedFileURL == url.standardizedFileURL
    }

    func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            windows = content.windows.filter { win in
                guard win.frame.width >= 32, win.frame.height >= 32 else { return false }
                if let app = win.owningApplication, app.applicationName == "ScreenVoiceRec" { return false }
                return true
            }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }

            displays = content.displays

            if selectedWindowID == nil, let first = windows.first {
                selectedWindowID = first.windowID
            }
            if selectedDisplayID == nil, let first = displays.first {
                selectedDisplayID = first.displayID
            }
            let loaded = L10n.tr("loaded.counts", windows.count, displays.count)
            var extra = ""
            if let path = lastRecordingURL?.path {
                extra += L10n.tr("recent.path", path)
            }
            statusMessage = loaded + extra
        } catch {
            statusMessage = L10n.tr("status.shareable_error", error.localizedDescription)
        }
    }

    func toggleRecord() {
        switch phase {
        case .idle:
            beginRecordingFlow()
        case .recording:
            pause()
        case .paused:
            resume()
        case .stopping:
            break
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        phase = .stopping
        statusMessage = L10n.tr("status.stopping")
        Task {
            if sourceKind == .headphoneJack {
                await micEngine.stop()
            } else {
                await engine.stop()
            }
        }
    }

    private func beginRecordingFlow() {
        guard !isPreparingRecording else { return }
        let url: URL
        do {
            let dir = try Self.ensureRecordingsDirectory()
            let name = "\(defaultFileName()).\(exportFormat.fileExtension)"
            url = dir.appendingPathComponent(name).standardizedFileURL
        } catch {
            statusMessage = L10n.tr("status.mkdir_error", error.localizedDescription)
            return
        }
        Task {
            isPreparingRecording = true
            defer { isPreparingRecording = false }
            if sourceKind != .headphoneJack {
                await refreshShareableContent()
            }
            await startRecording(outputURL: url)
        }
    }

    private func defaultFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return L10n.tr("recording.filename", f.string(from: Date()))
    }

    private func startRecording(outputURL: URL) async {
        if sourceKind == .headphoneJack {
            statusMessage = L10n.tr("status.starting_capture")
            do {
                try await micEngine.start(outputURL: outputURL, format: exportFormat)
                hasAudioSessionStarted = false
                recordingLevel = 0
                lastRecordingURL = outputURL
                phase = .recording
                statusMessage = L10n.tr("status.recording")
                startRecordingTimer(resetElapsed: true)
            } catch {
                phase = .idle
                lastRecordingURL = nil
                stopRecordingTimer()
                recordingElapsed = 0
                statusMessage = error.localizedDescription
            }
            return
        }

        guard let (filter, capW, capH) = makeRecordingSetup() else {
            statusMessage = L10n.tr("status.no_source")
            return
        }

        statusMessage = L10n.tr("status.starting_capture")

        do {
            try await engine.start(
                filter: filter,
                outputURL: outputURL,
                format: exportFormat,
                captureWidth: capW,
                captureHeight: capH
            )
            hasAudioSessionStarted = false
            recordingLevel = 0
            lastRecordingURL = outputURL
            phase = .recording
            statusMessage = L10n.tr("status.connecting_audio")
            startRecordingTimer(resetElapsed: true)
        } catch {
            phase = .idle
            lastRecordingURL = nil
            stopRecordingTimer()
            recordingElapsed = 0
            statusMessage = error.localizedDescription
        }
    }

    /// 与 Apple「Capturing screen content in macOS」一致：`SCStreamConfiguration` 宽高须匹配实际捕获分辨率，否则可能收不到音频。
    private func makeRecordingSetup() -> (SCContentFilter, Int, Int)? {
        switch sourceKind {
        case .headphoneJack:
            return nil
        case .window:
            guard let id = selectedWindowID,
                  let w = windows.first(where: { $0.windowID == id }) else { return nil }
            let f = w.frame
            let mid = CGPoint(x: f.midX, y: f.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
            let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let ww = max(64, Int(ceil(f.width * scale)))
            let hh = max(64, Int(ceil(f.height * scale)))
            return (SCContentFilter(desktopIndependentWindow: w), ww, hh)
        case .display:
            guard let id = selectedDisplayID,
                  let d = displays.first(where: { $0.displayID == id }) else { return nil }
            var ww = Int(CGDisplayPixelsWide(d.displayID))
            var hh = Int(CGDisplayPixelsHigh(d.displayID))
            if ww <= 0 || hh <= 0 {
                ww = 1920
                hh = 1080
            }
            ww = max(64, ww)
            hh = max(64, hh)
            // 整块显示器应使用 `excludingWindows:`；`excludingApplications: []` 在部分系统上会导致流异常或立即结束。
            return (SCContentFilter(display: d, excludingWindows: []), ww, hh)
        }
    }

    private func pause() {
        guard phase == .recording else { return }
        stopRecordingTimer()
        recordingLevel = 0
        if sourceKind == .headphoneJack {
            micEngine.setPaused(true)
        } else {
            engine.setPaused(true)
        }
        phase = .paused
        statusMessage = L10n.tr("status.paused")
    }

    private func resume() {
        guard phase == .paused else { return }
        if sourceKind == .headphoneJack {
            micEngine.setPaused(false)
        } else {
            engine.setPaused(false)
        }
        phase = .recording
        startRecordingTimer(resetElapsed: false)
        statusMessage = hasAudioSessionStarted ? L10n.tr("status.recording") : L10n.tr("status.resume.connecting")
    }

    private func handleEngineError(_ error: Error) {
        statusMessage = error.localizedDescription
        guard phase != .idle else { return }
        stopRecordingTimer()
        recordingElapsed = 0
        recordingLevel = 0
        hasAudioSessionStarted = false
        phase = .idle
        lastRecordingURL = nil
    }

    private func startRecordingTimer(resetElapsed: Bool) {
        stopRecordingTimer()
        if resetElapsed {
            recordingElapsed = 0
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.recordingElapsed += 0.05
            }
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    func revealRecordingInFinder() {
        if let u = lastRecordingURL, FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            return
        }
        if let u = playbackURL, !isAppRecordingFile(u), FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            return
        }
        statusMessage = L10n.tr("status.no_file_reveal")
    }

    func openAppRecordingsFolderInFinder() {
        do {
            let dir = try Self.ensureRecordingsDirectory()
            NSWorkspace.shared.open(dir)
        } catch {
            statusMessage = L10n.tr("status.open_folder_error", error.localizedDescription)
        }
    }

    func copyLastRecordingPathToPasteboard() {
        guard let path = lastRecordingURL?.path ?? playbackURL?.path else {
            statusMessage = L10n.tr("status.no_path_copy")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusMessage = L10n.tr("status.copy_path_ok")
    }

    // MARK: - Playback

    func pickPlaybackFile() {
        let panel = NSOpenPanel()
        var openTypes: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3]
        if let caf = UTType(filenameExtension: "caf") { openTypes.append(caf) }
        if let flac = UTType(filenameExtension: "flac") { openTypes.append(flac) }
        panel.allowedContentTypes = openTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L10n.tr("panel.choose_audio")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard replaceSecurityScopedAccess(with: url) else { return }
        playbackURL = url
        preparePlayer(url: url)
    }

    /// 是否有可尝试回放的音频（最近录音或已选文件）。
    var hasPlaybackSource: Bool {
        lastRecordingURL != nil || playbackURL != nil
    }

    /// 是否可对当前进度执行「停止并回到开头」（已载入播放器且正在播或不在零秒）。
    var canStopPlayback: Bool {
        isPlaybackReady && (isPlaying || playbackCurrentTime > 0.05)
    }

    private func playbackTargetURL() -> URL? {
        playbackURL ?? lastRecordingURL
    }

    /// 载入 `playbackTargetURL()` 对应的 `AVPlayer`；成功返回 `true`。
    @discardableResult
    private func preparePlaybackPlayerIfNeeded() -> Bool {
        guard let target = playbackTargetURL() else {
            statusMessage = L10n.tr("status.need_playback")
            return false
        }
        if !isAppRecordingFile(target), !hasSecurityScopeForSameFile(as: target) {
            guard replaceSecurityScopedAccess(with: target) else { return false }
        }
        if player == nil || preparedPlaybackURL?.standardizedFileURL != target.standardizedFileURL {
            playbackURL = target
            preparePlayer(url: target)
        }
        guard player != nil else {
            statusMessage = L10n.tr("status.player_init_error")
            return false
        }
        return true
    }

    /// 播放（若已在末尾则从头再播）。
    func playbackPlay() {
        guard preparePlaybackPlayerIfNeeded() else { return }
        guard let player else { return }
        if playbackDuration > 0, playbackCurrentTime >= playbackDuration - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    self?.playbackCurrentTime = 0
                    self?.player?.play()
                    self?.isPlaying = true
                }
            }
            statusMessage = L10n.tr("status.playing")
            return
        }
        player.play()
        isPlaying = true
        statusMessage = L10n.tr("status.playing")
    }

    /// 暂停当前回放。
    func playbackPause() {
        player?.pause()
        isPlaying = false
        if isPlaybackReady {
            statusMessage = L10n.tr("status.playback_paused")
        }
    }

    /// 停止回放并回到开头（与录音「停止」无关）。
    func stopPlayback() {
        player?.pause()
        isPlaying = false
        guard let p = player else {
            playbackCurrentTime = 0
            return
        }
        p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.playbackCurrentTime = 0
            }
        }
        statusMessage = L10n.tr("status.playback_stopped")
    }

    /// 播放 ↔ 暂停切换（空格等快捷键用）。
    func playbackTogglePlayPause() {
        guard hasPlaybackSource else {
            statusMessage = L10n.tr("status.need_playback")
            return
        }
        if isPlaying {
            playbackPause()
        } else {
            playbackPlay()
        }
    }

    func playOrPauseLastRecording() {
        playbackTogglePlayPause()
    }

    private func preparePlayer(url: URL) {
        preparedPlaybackURL = nil
        isPlaybackReady = false
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        if let o = playbackEndObserver {
            NotificationCenter.default.removeObserver(o)
            playbackEndObserver = nil
        }
        removePlaybackTimeObserver()
        player?.pause()
        playbackCurrentTime = 0
        playbackDuration = 0
        isPlaybackScrubbing = false

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p

        playerItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                if observed.status == .failed {
                    let err = observed.error?.localizedDescription ?? L10n.tr("error.unknown")
                    self.statusMessage = L10n.tr("status.playback_failed", err)
                }
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        playbackTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isPlaybackScrubbing else { return }
                self.playbackCurrentTime = CMTimeGetSeconds(time)
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.playbackCurrentTime = self?.playbackDuration ?? 0
            }
        }

        Task { @MainActor in
            if let d = try? await asset.load(.duration), d.isValid, !d.isIndefinite {
                let sec = CMTimeGetSeconds(d)
                if sec.isFinite, sec >= 0 {
                    self.playbackDuration = sec
                }
            }
        }

        isPlaying = false
        preparedPlaybackURL = url.standardizedFileURL
        isPlaybackReady = true
        statusMessage = L10n.tr("status.loaded_file", url.lastPathComponent)
    }

    private func removePlaybackTimeObserver() {
        if let token = playbackTimeObserver, let p = player {
            p.removeTimeObserver(token)
        }
        playbackTimeObserver = nil
    }

    func setPlaybackScrubbing(_ editing: Bool) {
        isPlaybackScrubbing = editing
        if !editing {
            seekPlayback(to: playbackCurrentTime)
        }
    }

    func seekPlayback(to seconds: TimeInterval) {
        let s = max(0, min(seconds, max(playbackDuration, 0)))
        let t = CMTime(seconds: s, preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

enum TimeFormatting {
    static func mmss(_ t: TimeInterval) -> String {
        let x = max(0, t)
        let total = Int(x.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    static func hmmss(_ t: TimeInterval) -> String {
        let x = max(0, t)
        let total = Int(x.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

enum RecordingPhase: Equatable {
    case idle
    case recording
    case paused
    case stopping
}
