import Foundation

/// Dictation audio files (Mac). Their names start with `prefix`, which is how the fake engine knows to return the
/// dictation sentence instead of its recording script.
public enum DictationFiles {
    public static let prefix = "dictation-"
}
