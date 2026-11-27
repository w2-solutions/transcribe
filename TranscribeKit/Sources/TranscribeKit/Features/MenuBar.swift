import Foundation

/// The Mac's menu bar item (Mac only): the logo's bars, with a record dot beside them while a meeting records, and a
/// short menu. Pure, so its rules are tested here; `MacMenuBar` in the Mac app draws it.
public struct MenuBarState: Equatable, Sendable {
    public enum Icon: Equatable, Sendable { case idle, recording }

    public var icon: Icon
    /// The icon's accessibility label.
    public var label: String
    /// "New Recording", or "Stop Recording" while a meeting records.
    public var recordTitle: String
    /// Whether the record item can be chosen.
    public var recordEnabled: Bool

    /// The icon shows a recording whenever the recorder is not idle, as the Dock badge does. The record item does what
    /// the "Start or stop a recording" shortcut does, and is off where that shortcut would do nothing: before launch
    /// has finished, during a dictation, and while a recording is starting or stopping.
    public static func resolve(recorder: RecorderController.State, dictationBusy: Bool, launched: Bool) -> MenuBarState {
        let active = recorder != .idle
        let settled: Bool
        switch recorder {
        case .idle, .recording, .paused: settled = true
        case .starting, .stopping: settled = false
        }
        return MenuBarState(icon: active ? .recording : .idle,
                            label: active ? MenuBarCopy.labelRecording : MenuBarCopy.label,
                            recordTitle: active ? MenuBarCopy.stopRecording : MenuBarCopy.newRecording,
                            recordEnabled: launched && !dictationBusy && settled)
    }
}

/// Every string of the menu bar item.
public enum MenuBarCopy {
    public static let label = "Transcribe"
    public static let labelRecording = "Transcribe, recording"
    public static let newRecording = "New Recording"
    public static let stopRecording = "Stop Recording"
    public static let openApp = "Open Transcribe"
    public static let settings = "Settings…"
    public static let quit = "Quit Transcribe"

    /// The HUD after New Recording in the menu with another app in front. Unlike the shortcut's
    /// (`DictationHUD.meetingStarted`) it names no key, since none was pressed.
    public static let recordingStarted = HUDMessage(symbol: "record.circle.fill", title: "Recording started",
                                                    tone: .record, seconds: 2.5)
}
