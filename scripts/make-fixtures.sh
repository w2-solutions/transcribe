#!/usr/bin/env bash
# Generates the audio fixtures for the gated FluidAudio tests (TranscribeFluidTests, §8.1).
# Uses macOS `say` (voices Daniel, Karen and Moira) and `afconvert`; the WAVs are 16 kHz mono 16-bit (LEI16)
# and are gitignored. Run once, then:
#   TRANSCRIBE_MODELS_DIR=<dir> swift test --filter TranscribeFluidTests   (from TranscribeKit/)
#
#   two-voices.wav  ~24 s, four alternating turns (Daniel, Karen, Daniel, Karen); contains "transcription"
#   three-voices.wav ~30 s, nine turns by Daniel, Karen and Moira with quick (0.15 s) handovers and short replies
#   *.turns.json    the true turns (voice, start, end) of the two- and three-voice files, for coverage checks
#   voice-a.wav     Daniel only, two sentences with a pause between them
#   voice-b.wav     Karen only, two sentences with a pause between them
#   silence.wav     5 s of digital silence (separation must report no speech)
#   short.wav       0.2 s of silence (below Parakeet's 0.3 s minimum)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/TranscribeKit/Tests/TranscribeFluidTests/Fixtures"
VOICE_A="${VOICE_A:-Daniel}"
VOICE_B="${VOICE_B:-Karen}"
VOICE_C="${VOICE_C:-Moira}"
GAP_SECONDS="${GAP_SECONDS:-0.4}"
QUICK_GAP_SECONDS="${QUICK_GAP_SECONDS:-0.15}"

for tool in say afconvert python3; do
  command -v "$tool" >/dev/null || { echo "make-fixtures: '$tool' is required" >&2; exit 1; }
done
for voice in "$VOICE_A" "$VOICE_B" "$VOICE_C"; do
  say -v '?' | awk '{print $1}' | grep -qx "$voice" || {
    echo "make-fixtures: voice '$voice' is not installed (System Settings > Accessibility > Spoken Content)" >&2
    exit 1
  }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-fixtures.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

A1="Good morning, and thanks for joining the call about the new transcription app for the iPhone."
B1="Happy to help. I have been testing the recorder all week and the battery life looks fine."
A2="Great. The next step is speaker separation, which runs after the recording finishes."
B2="Sounds good. Let's check the voice profiles on Friday and tune the matching thresholds then."

# render <voice> <name> <text>: say → AIFF → 16 kHz mono LEI16 WAV
render() {
  say -v "$1" -o "$WORK/$2.aiff" "$3"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$2.aiff" "$WORK/$2.wav"
}

render "$VOICE_A" a1 "$A1"
render "$VOICE_B" b1 "$B1"
render "$VOICE_A" a2 "$A2"
render "$VOICE_B" b2 "$B2"

# Three voices, quick handovers and a few one-line replies.
C1="Before we move on, can I ask how the app copes when three of us talk in one meeting?"
A3="It should be fine. Each voice gets its own colour after the recording ends."
C2="Right."
B3="And if two people sound alike, it asks before it puts a name on anyone."
A4="Exactly."
C3="Then let's record the Monday standup and compare the labels against our notes."
B4="Okay, I'll set it up."
render "$VOICE_C" c1 "$C1"
render "$VOICE_A" a3 "$A3"
render "$VOICE_C" c2 "$C2"
render "$VOICE_B" b3 "$B3"
render "$VOICE_A" a4 "$A4"
render "$VOICE_C" c3 "$C3"
render "$VOICE_B" b4 "$B4"

# Joins WAVs (inserting silence between them) and writes canonical 44-byte-header WAVs.
# afconvert output can carry extra chunks (e.g. FLLR), so the frames are read with the wave module.
# An input written "<voice>=<path>" is recorded in "<out minus .wav>.turns.json" as a true turn: the span between
# its first and last non-silent sample (|x| > 1% full scale), so `say`'s leading and trailing silence is excluded.
JOIN_PY='
import array, json, sys, wave
gap, out, inputs = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
rate = 16000
frames = b""
turns = []
for i, item in enumerate(inputs):
    if item.startswith("silence:"):
        frames += b"\x00\x00" * int(float(item.split(":")[1]) * rate)
        continue
    voice, _, path = item.rpartition("=")
    with wave.open(path, "rb") as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (rate, 1, 2), path
        if i > 0 and frames:
            frames += b"\x00\x00" * int(gap * rate)
        data = w.readframes(w.getnframes())
    if voice:
        samples = array.array("h", data)
        loud = [k for k, x in enumerate(samples) if abs(x) > 327]
        offset = len(frames) // 2
        if loud:
            turns.append({"voice": voice, "start": round((offset + loud[0]) / rate, 3),
                          "end": round((offset + loud[-1] + 1) / rate, 3)})
    frames += data
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(frames)
if turns:
    with open(out[:-4] + ".turns.json", "w") as f:
        json.dump(turns, f, indent=1)
print(f"{out}: {len(frames) / 2 / rate:.2f} s" + (f", {len(turns)} turns" if turns else ""))
'
join() { python3 -I -c "$JOIN_PY" "$@"; }

join "$GAP_SECONDS" "$OUT/two-voices.wav" "A=$WORK/a1.wav" "B=$WORK/b1.wav" "A=$WORK/a2.wav" "B=$WORK/b2.wav"
join "$QUICK_GAP_SECONDS" "$OUT/three-voices.wav" "A=$WORK/a1.wav" "B=$WORK/b1.wav" "C=$WORK/c1.wav" "A=$WORK/a3.wav" \
  "C=$WORK/c2.wav" "B=$WORK/b3.wav" "A=$WORK/a4.wav" "C=$WORK/c3.wav" "B=$WORK/b4.wav"
join 1.0 "$OUT/voice-a.wav" "$WORK/a1.wav" "$WORK/a2.wav"
join 1.0 "$OUT/voice-b.wav" "$WORK/b1.wav" "$WORK/b2.wav"
join 0 "$OUT/silence.wav" "silence:5"
join 0 "$OUT/short.wav" "silence:0.2"

for f in two-voices three-voices voice-a voice-b silence short; do
  afinfo "$OUT/$f.wav" | grep -E "Data format|estimated duration" | sed "s|^|  $f: |"
done
