#!/bin/bash
# Fills BundledModels/ with the speech models the app ships, exactly as pinned in scripts/models.lock.
#
#   ./scripts/fetch-models.sh                  fetch what is missing or wrong (idempotent)  = make models
#   ./scripts/fetch-models.sh --from DIR       copy matching files from DIR first (APFS clone), download the rest
#                                              DIR may be an old BundledModels or ~/Library/Caches/transcribe-test-models
#   ./scripts/fetch-models.sh --update-lock    re-read the pins below from Hugging Face, rewrite models.lock, then fetch
#
# Every file is checked by size and sha256 against the lock. Anything in BundledModels that the lock does not
# list (FluidAudio .fluidaudio-* markers, *.partial files, .DS_Store, stale files) is deleted, so the folder
# carries no hidden files into the app. BundledModels is gitignored apart from its README: never commit models.
# Runs on macOS /bin/bash 3.2; needs curl, shasum, stat and jq (/usr/bin/jq on macOS 15 and later).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="BundledModels"
LOCK="scripts/models.lock"
HF="https://huggingface.co"

# Must equal ModelNames.Nemotron3.weightsVersion in the pinned FluidAudio (a swift test checks the lock).
NEMOTRON_WEIGHTS="ga-2026-09-23"

# One set per line, tab-separated: folder, repo, revision, prefix stripped from remote paths ("-" for none),
# selections (space-separated; a trailing "/" means the whole remote folder). Change these only together with
# --update-lock. Parakeet and Nemotron are the commits FluidAudio's "main" pointed at when pinned; the diarizer
# revision is Repo.diarizer.revision. Nemotron is stored flat for Nemotron3Models.load(config:directory:).
PINS="parakeet-tdt-0.6b-v3	FluidInference/parakeet-tdt-0.6b-v3-coreml	7dd20fe6b1797d35f5e3307e8b1732d9a178edfe	-	Preprocessor.mlmodelc/ Encoder.mlmodelc/ Decoder.mlmodelc/ JointDecisionv3.mlmodelc/ parakeet_vocab.json
speaker-diarization	FluidInference/speaker-diarization-coreml	df2625ac79a7ac6b65ad868fee6d80f320da4232	-	Segmentation.mlmodelc/ FBank.mlmodelc/ Embedding.mlmodelc/ PldaRho.mlmodelc/ plda-parameters.json
nemotron-3-diarization	FluidInference/nemotron-3-diarization-coreml	25a90f97f254428d4b30374b76af9c74fdee8327	monolithic/v2/	monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc/ learnable_sil_emb.bin"

SAFE_PATH='^[A-Za-z0-9._/-]+$'
HEX40='^[0-9a-f]{40}$'
HEX64='^[0-9a-f]{64}$'
TAB="$(printf '\t')"

usage() {
  echo "usage: $0 [--from DIR] [--update-lock]" >&2
  exit 2
}

FROM=""
UPDATE_LOCK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || usage
      FROM="$2"
      shift 2
      ;;
    --update-lock)
      UPDATE_LOCK=1
      shift
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
if [ -n "$FROM" ] && [ ! -d "$FROM" ]; then
  echo "error: --from $FROM is not a folder" >&2
  exit 1
fi

for tool in curl shasum stat jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool is required" >&2
    exit 1
  }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fetch-models.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

file_size() { stat -f %z "$1"; }
file_sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

# matches PATH SIZE SHA: a regular file (not a symlink) with that size and sha256.
matches() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(file_size "$1")" = "$2" ] || return 1
  [ "$(file_sha "$1")" = "$3" ]
}

# A remote or local path the scripts will accept: plain characters, no "." or ".." components, no dotfiles.
check_path() {
  [[ $1 =~ $SAFE_PATH ]] || die "unsafe path in models: $1"
  case "/$1/" in
    */./* | */../* | *//* | */.*) die "unsafe path in models: $1" ;;
  esac
}

# ---------------------------------------------------------------- --update-lock

# list_tree REPO REV DIR RECURSIVE OUT: Hugging Face tree listing of DIR ("" for the root) as
# "path<TAB>size<TAB>lfs-sha256-or-empty" lines for files only. Fails on a paginated (incomplete) listing.
list_tree() {
  local repo="$1" rev="$2" dir="$3" recursive="$4" out="$5" url
  url="$HF/api/models/$repo/tree/$rev"
  [ -z "$dir" ] || url="$url/$dir"
  [ "$recursive" = 0 ] || url="$url?recursive=true"
  curl -fsS --retry 3 --retry-delay 2 -D "$WORK/headers" -o "$WORK/tree.json" "$url" ||
    die "could not list $url"
  if grep -i '^link:' "$WORK/headers" | grep -q 'rel="next"'; then
    die "the listing of $url is paginated; this script cannot read it completely"
  fi
  jq -r '.[] | select(.type == "file") | [.path, ((.lfs.size // .size) | tostring), (.lfs.oid // "")] | @tsv' \
    "$WORK/tree.json" >"$out"
}

update_lock() {
  local version rows folder repo rev strip sels sel dir path size lfs sha local_path found tmp_dl
  version="$(jq -r '.pins[] | select(.identity == "fluidaudio") | .state.version' TranscribeKit/Package.resolved)"
  [ -n "$version" ] && [ "$version" != null ] || die "no fluidaudio version in TranscribeKit/Package.resolved"
  rows="$WORK/rows"
  : >"$rows"

  while IFS="$TAB" read -r folder repo rev strip sels <&3; do
    [ -n "$folder" ] || continue
    [[ $rev =~ $HEX40 ]] || die "revision for $repo is not a full commit hash: $rev"
    echo "Listing $repo@${rev:0:8}…"
    for sel in $sels; do
      case "$sel" in
        */)
          dir="${sel%/}"
          list_tree "$repo" "$rev" "$dir" 1 "$WORK/list"
          found=0
          while IFS="$TAB" read -r path size lfs <&4; do
            case "$path" in "$dir"/*) ;; *) continue ;; esac
            found=1
            echo "$path$TAB$size$TAB$lfs" >>"$WORK/sel"
          done 4<"$WORK/list"
          [ "$found" = 1 ] || die "$repo@$rev has no files under $sel"
          ;;
        *)
          dir="$(dirname "$sel")"
          [ "$dir" != . ] || dir=""
          list_tree "$repo" "$rev" "$dir" 0 "$WORK/list"
          awk -F '\t' -v p="$sel" '$1 == p' "$WORK/list" >"$WORK/one"
          [ -s "$WORK/one" ] || die "$repo@$rev has no file $sel"
          cat "$WORK/one" >>"$WORK/sel"
          ;;
      esac
    done

    while IFS="$TAB" read -r path size lfs <&4; do
      check_path "$path"
      [[ $size =~ ^[0-9]+$ ]] || die "bad size for $repo/$path: $size"
      local_path="$path"
      if [ "$strip" != "-" ]; then
        case "$path" in "$strip"*) local_path="${path#"$strip"}" ;; esac
      fi
      local_path="$folder/$local_path"
      check_path "$local_path"
      if [ -n "$lfs" ]; then
        sha="$lfs"
      else
        # Not in LFS, so the listing only has a git blob id: download it to hash it.
        tmp_dl="$WORK/blob"
        curl -fsSL --retry 3 --retry-delay 2 -o "$tmp_dl" "$HF/$repo/resolve/$rev/$path" ||
          die "could not download $repo/$path"
        [ "$(file_size "$tmp_dl")" = "$size" ] || die "size of $repo/$path does not match its listing"
        sha="$(file_sha "$tmp_dl")"
        rm -f "$tmp_dl"
      fi
      [[ $sha =~ $HEX64 ]] || die "bad sha256 for $repo/$path: $sha"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$local_path" "$repo" "$rev" "$path" "$size" "$sha" >>"$rows"
    done 4<"$WORK/sel"
    rm -f "$WORK/sel"

    # Licence files are not shipped; print them so the Attributions screen can be checked by hand.
    list_tree "$repo" "$rev" "" 0 "$WORK/list"
    awk -F '\t' 'toupper($1) ~ /^(LICENSE|LICENCE|NOTICE)/ { print $1 }' "$WORK/list" | while read -r path; do
      echo "  note: $repo has $path — check Attributions: $HF/$repo/blob/$rev/$path"
    done
  done 3<<EOF
$PINS
EOF

  local dupes
  dupes="$(cut -f 1 "$rows" | LC_ALL=C sort | uniq -d)"
  [ -z "$dupes" ] || die "two remote files map to the same local path: $dupes"

  {
    echo "# Speech models shipped in Transcribe.app/BundledModels. Generated by"
    echo "#   ./scripts/fetch-models.sh --update-lock"
    echo "# Do not edit by hand. Columns (tab-separated): local_path repo revision remote_path size sha256"
    echo "@fluidaudio${TAB}$version"
    echo "@nemotron3-weights${TAB}$NEMOTRON_WEIGHTS"
    LC_ALL=C sort -t "$TAB" -k 1,1 "$rows"
  } >"$LOCK.tmp"
  mv "$LOCK.tmp" "$LOCK"
  echo "Wrote $LOCK ($(wc -l <"$rows" | tr -d ' ') files, FluidAudio $version)"
}

[ "$UPDATE_LOCK" = 0 ] || update_lock

# ---------------------------------------------------------------- fetch

[ -f "$LOCK" ] || die "$LOCK is missing (run with --update-lock to create it)"
mkdir -p "$DEST"

copied=0
downloaded=0
kept=0
: >"$WORK/wanted"
echo "README.md" >>"$WORK/wanted"

while IFS="$TAB" read -r local_path repo rev remote_path size sha extra <&3; do
  case "$local_path" in "" | "#"* | "@"*) continue ;; esac
  [ -z "$extra" ] || die "bad lock row (more than six columns): $local_path"
  check_path "$local_path"
  check_path "$remote_path"
  [[ $rev =~ $HEX40 ]] || die "bad revision in lock row $local_path"
  [[ $size =~ ^[0-9]+$ ]] || die "bad size in lock row $local_path"
  [[ $sha =~ $HEX64 ]] || die "bad sha256 in lock row $local_path"
  echo "$local_path" >>"$WORK/wanted"

  target="$DEST/$local_path"
  if matches "$target" "$size" "$sha"; then
    kept=$((kept + 1))
    continue
  fi
  mkdir -p "$(dirname "$target")"
  rm -rf "$target"

  if [ -n "$FROM" ]; then
    folder="${local_path%%/*}"
    src=""
    for candidate in "$FROM/$local_path" "$FROM/$folder/$remote_path"; do
      if matches "$candidate" "$size" "$sha"; then
        src="$candidate"
        break
      fi
    done
    if [ -n "$src" ]; then
      rm -f "$target.partial"
      cp -c "$src" "$target.partial" 2>/dev/null || cp "$src" "$target.partial"
      mv "$target.partial" "$target"
      copied=$((copied + 1))
      continue
    fi
  fi

  if [ "$size" = 0 ]; then
    : >"$target"
    matches "$target" "$size" "$sha" || die "the lock's hash for empty file $local_path is wrong"
    downloaded=$((downloaded + 1))
    continue
  fi

  partial="$target.partial"
  if [ -f "$partial" ]; then
    have="$(file_size "$partial")"
    if [ "$have" -gt "$size" ] || { [ "$have" = "$size" ] && ! matches "$partial" "$size" "$sha"; }; then
      rm -f "$partial"
    fi
  fi
  if ! matches "$partial" "$size" "$sha"; then
    echo "Downloading $repo/$remote_path ($size bytes)…"
    curl -fL --progress-bar --retry 3 --retry-delay 2 -C - -o "$partial" "$HF/$repo/resolve/$rev/$remote_path" ||
      die "download failed: $HF/$repo/resolve/$rev/$remote_path (run again to resume)"
    if ! matches "$partial" "$size" "$sha"; then
      rm -f "$partial"
      die "$local_path does not match models.lock after download (size or sha256)"
    fi
  fi
  mv "$partial" "$target"
  downloaded=$((downloaded + 1))
done 3<"$LOCK"

# Prune everything the lock does not list (markers, partials, .DS_Store, stale files), then empty folders.
LC_ALL=C sort -u "$WORK/wanted" >"$WORK/wanted.sorted"
(cd "$DEST" && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort) >"$WORK/present"
LC_ALL=C comm -23 "$WORK/present" "$WORK/wanted.sorted" >"$WORK/extra"
while IFS= read -r path; do
  echo "Removing $DEST/$path (not in $LOCK)"
  rm -f "$DEST/$path"
done <"$WORK/extra"
find "$DEST" -mindepth 1 -type d -empty -delete

total="$(grep -c "^[^#@]" "$LOCK" || true)"
echo "Bundled models: $total files ($kept already present, $copied copied, $downloaded downloaded); $(du -sh "$DEST" | cut -f 1) in $DEST"
