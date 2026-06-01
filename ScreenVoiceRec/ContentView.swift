//
//  ContentView.swift
//  ScreenVoiceRec
//

import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = ScreenRecorderViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("app.title"))
                .font(.title2.weight(.semibold))

            GroupBox(L10n.tr("source.group")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.tr("picker.type"), selection: $model.sourceKind) {
                        ForEach(CaptureSourceKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    switch model.sourceKind {
                    case .headphoneJack:
                        Text(L10n.tr("source.headphone.hint"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .window:
                        if model.windows.isEmpty {
                            Text(L10n.tr("source.empty.windows"))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(L10n.tr("picker.window"), selection: $model.selectedWindowID) {
                                ForEach(model.windows, id: \.windowID) { w in
                                    let name = w.owningApplication?.applicationName ?? L10n.tr("window.app_fallback")
                                    let title = (w.title?.isEmpty == false) ? w.title! : L10n.tr("window.untitled")
                                    Text("\(name) — \(title)").tag(Optional(w.windowID))
                                }
                            }
                            .frame(minWidth: 320)
                        }
                    case .display:
                        if model.displays.isEmpty {
                            Text(L10n.tr("source.empty.displays"))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(L10n.tr("picker.display"), selection: $model.selectedDisplayID) {
                                ForEach(model.displays, id: \.displayID) { d in
                                    Text(displayLabel(d)).tag(Optional(d.displayID))
                                }
                            }
                        }
                    }

                    Button(L10n.tr("source.refresh")) {
                        Task { await model.refreshShareableContent() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(L10n.tr("export.group")) {
                Picker(L10n.tr("export.format"), selection: $model.exportFormat) {
                    ForEach(AudioExportFormat.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(L10n.tr("save.group")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.recordingsFolderSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Text(L10n.tr("save.hint"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GroupBox(L10n.tr("control.group")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: { model.toggleRecord() }) {
                            Label(
                                model.isPreparingRecording
                                    ? L10n.tr("record.preparing")
                                    : (model.phase == .paused ? L10n.tr("record.resume") : (model.phase == .recording ? L10n.tr("record.pause") : L10n.tr("record.start"))),
                                systemImage: model.phase == .recording ? "pause.fill" : "record.circle"
                            )
                        }
                        .keyboardShortcut("r", modifiers: [.command])
                        .disabled(model.phase == .stopping || model.isPreparingRecording)

                        Button(L10n.tr("record.stop")) {
                            model.stop()
                        }
                        .keyboardShortcut(".", modifiers: [.command])
                        .disabled(model.phase != .recording && model.phase != .paused)
                    }

                    recordingTimeline
                }
            }

            GroupBox(L10n.tr("playback.group")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.pickPlaybackFile()
                        } label: {
                            Label(L10n.tr("playback.choose_file"), systemImage: "folder")
                        }
                        .help(L10n.tr("playback.help.open_file"))

                        Button {
                            model.playbackPlay()
                        } label: {
                            Label(L10n.tr("playback.play"), systemImage: "play.fill")
                        }
                        .disabled(!model.hasPlaybackSource || model.isPlaying)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help(L10n.tr("playback.help.play"))

                        Button {
                            model.playbackPause()
                        } label: {
                            Label(L10n.tr("playback.pause"), systemImage: "pause.fill")
                        }
                        .disabled(!model.isPlaying)
                        .keyboardShortcut(KeyEquivalent("/"), modifiers: [.command])
                        .help(L10n.tr("playback.help.pause"))

                        Button {
                            model.stopPlayback()
                        } label: {
                            Label(L10n.tr("playback.stop"), systemImage: "stop.fill")
                        }
                        .disabled(!model.canStopPlayback)
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .help(L10n.tr("playback.help.stop"))
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.playbackTogglePlayPause()
                        } label: {
                            Label(
                                model.isPlaying ? L10n.tr("playback.toggle_pause") : L10n.tr("playback.toggle_play"),
                                systemImage: model.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                            )
                        }
                        .disabled(!model.hasPlaybackSource)
                        .keyboardShortcut(.space, modifiers: [])
                        .help(L10n.tr("playback.help.space"))

                        Button(L10n.tr("playback.reveal")) {
                            model.revealRecordingInFinder()
                        }
                        Button(L10n.tr("playback.open_folder")) {
                            model.openAppRecordingsFolderInFinder()
                        }
                        Button(L10n.tr("playback.copy_path")) {
                            model.copyLastRecordingPathToPasteboard()
                        }
                    }

                    playbackTimeline

                    if let path = model.lastRecordingURL?.path {
                        Text(L10n.tr("recent.file", path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    Text(L10n.tr("playback.shortcuts.hint"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 540)
        .task {
            await model.refreshShareableContent()
        }
    }

    private var recordingTimelineIcon: String {
        switch model.phase {
        case .recording: return "waveform.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle.fill"
        case .idle: return "record.circle"
        }
    }

    private func displayLabel(_ d: SCDisplay) -> String {
        let w = Int(d.width)
        let h = Int(d.height)
        return L10n.tr("display.label", UInt(d.displayID), w, h)
    }

    private var recordingTimeline: some View {
        let active = model.phase == .recording || model.phase == .paused || model.phase == .stopping
        let elapsed = model.recordingElapsed
        let level = CGFloat(model.recordingLevel)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: recordingTimelineIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.red : Color.secondary)
                Text(TimeFormatting.mmss(elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                if active, model.phase != .paused {
                    Text(L10n.tr("meter.input_level"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int((model.recordingLevel * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.phase == .paused {
                    Text(L10n.tr("meter.paused"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !active {
                    Text(L10n.tr("meter.idle"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.75), Color.red.opacity(0.95)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * level))
                }
            }
            .frame(height: 10)
            .accessibilityLabel(L10n.tr("a11y.meter"))
            .accessibilityValue("\(Int((model.recordingLevel * 100).rounded()))%")

            Text(L10n.tr("meter.hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var playbackTimeline: some View {
        let duration = max(model.playbackDuration, 0.01)
        let hasMedia = model.playbackURL != nil || model.lastRecordingURL != nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(TimeFormatting.hmmss(model.playbackCurrentTime))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text(TimeFormatting.hmmss(model.playbackDuration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { model.playbackCurrentTime },
                    set: { model.playbackCurrentTime = $0 }
                ),
                in: 0...duration,
                label: { Text(L10n.tr("playback.slider.label")) }
            ) { editing in
                model.setPlaybackScrubbing(editing)
            }
            .disabled(!hasMedia)

            Text(L10n.tr("playback.slider.hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    ContentView()
}
