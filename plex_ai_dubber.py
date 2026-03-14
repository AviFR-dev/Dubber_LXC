#!/usr/bin/env python3
"""
Plex AI Dubber - NAS Edition
Author: Avi Fridlindas
License: MIT

Dub a movie from your Plex library into another language using
open-source AI models with voice cloning.

Usage:
    source /opt/dubber/bin/activate

    # Preview (doesn't touch original):
    python plex_ai_dubber.py \
        --plex-url http://PLEX_IP:32400 \
        --plex-token YOUR_TOKEN \
        --hf-token hf_YOUR_TOKEN \
        --movie "The Matrix" \
        --target-lang spa \
        --tts coqui \
        --no-mux

    # Full (adds new audio track to file):
    python plex_ai_dubber.py \
        --plex-url http://PLEX_IP:32400 \
        --plex-token YOUR_TOKEN \
        --hf-token hf_YOUR_TOKEN \
        --movie "The Matrix" \
        --target-lang spa \
        --tts coqui
"""

import argparse
import os
import subprocess
import sys
import shutil
import json
from pathlib import Path
from datetime import datetime

# ============ DEFAULT CONFIG ============
DEFAULT_TARGET_LANG = "spa"
DEFAULT_SOURCE_LANG = "eng"
DEFAULT_TTS = "coqui"
DEFAULT_DEVICE = "cpu"
DEFAULT_OUTPUT_DIR = "/opt/dubber/output"
# Path mapping: Plex and Dubber LXC both mount NAS at /media/movies
# so no mapping needed. If paths ever differ, set these:
PLEX_PATH_PREFIX = ""
LOCAL_PATH_PREFIX = ""
# ========================================


def log(msg, level="*"):
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{timestamp}] [{level}] {msg}")


def check_dependencies():
    """Check that all required tools are installed."""
    missing = []

    for cmd, pkg in [("ffmpeg", "ffmpeg"), ("mkvmerge", "mkvtoolnix"), ("espeak-ng", "espeak-ng")]:
        if not shutil.which(cmd):
            missing.append(f"  {cmd} → apt install {pkg}")

    try:
        import plexapi
    except ImportError:
        missing.append("  plexapi → pip install plexapi")

    try:
        result = subprocess.run(["open-dubbing", "--help"], capture_output=True, timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        missing.append("  open-dubbing → pip install open_dubbing")

    # Check GPU
    gpu_available = False
    try:
        result = subprocess.run(["nvidia-smi"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            gpu_available = True
            for line in result.stdout.split("\n"):
                if "GTX" in line or "RTX" in line or "Tesla" in line:
                    log(f"GPU detected: {line.strip()}")
                    break
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    if missing:
        log("Missing dependencies:", "ERROR")
        print("\n".join(missing))
        sys.exit(1)

    log("All dependencies OK")
    return gpu_available


def map_path(plex_path):
    """Map Plex file path to local path if path prefixes are configured."""
    if PLEX_PATH_PREFIX and LOCAL_PATH_PREFIX:
        if plex_path.startswith(PLEX_PATH_PREFIX):
            return plex_path.replace(PLEX_PATH_PREFIX, LOCAL_PATH_PREFIX, 1)
    return plex_path


def connect_plex(plex_url, plex_token):
    """Connect to Plex server."""
    from plexapi.server import PlexServer
    log(f"Connecting to Plex at {plex_url}...")
    server = PlexServer(plex_url, plex_token)
    log(f"Connected: {server.friendlyName}")
    return server


def find_movie(server, movie_name):
    """Search for a movie in Plex."""
    log(f"Searching for '{movie_name}'...")
    results = server.search(movie_name, mediatype="movie")

    if not results:
        log(f"Movie '{movie_name}' not found!", "ERROR")
        print("\n  Available movies (first 30):")
        for section in server.library.sections():
            if section.type == "movie":
                for m in section.all()[:30]:
                    print(f"    - {m.title} ({m.year})")
        sys.exit(1)

    if len(results) > 1:
        log(f"Found {len(results)} results:")
        for i, r in enumerate(results):
            print(f"    [{i}] {r.title} ({r.year})")
        print(f"  Using first result. Use exact title if wrong.")

    movie = results[0]
    log(f"Found: {movie.title} ({movie.year})")
    return movie


def get_movie_file(movie, movie_path_override=None):
    """Get the movie file path, with NAS path mapping."""
    if movie_path_override:
        filepath = movie_path_override
    else:
        filepath = movie.media[0].parts[0].file
        log(f"Plex file path: {filepath}")
        filepath = map_path(filepath)

    log(f"Local file path: {filepath}")

    if not os.path.exists(filepath):
        log(f"File NOT found at: {filepath}", "ERROR")
        print(f"""
  The file path from Plex doesn't match this LXC's mount.
  Plex sees:  {movie.media[0].parts[0].file}
  Local path: {filepath}

  Fix options:
  1. Edit PLEX_PATH_PREFIX and LOCAL_PATH_PREFIX in the script
  2. Use --movie-path /actual/path/to/movie.mkv
  3. Make sure the NAS is mounted at the same path
        """)
        sys.exit(1)

    size_gb = os.path.getsize(filepath) / (1024**3)
    log(f"File size: {size_gb:.1f} GB")

    # Show existing audio tracks
    probe_cmd = [
        "ffprobe", "-v", "quiet", "-select_streams", "a",
        "-show_entries", "stream=index,codec_name:stream_tags=language,title",
        "-of", "json", filepath
    ]
    result = subprocess.run(probe_cmd, capture_output=True, text=True)
    if result.returncode == 0:
        probe = json.loads(result.stdout)
        streams = probe.get("streams", [])
        if streams:
            log(f"Existing audio tracks ({len(streams)}):")
            for s in streams:
                tags = s.get("tags", {})
                lang = tags.get("language", "unknown")
                title = tags.get("title", "")
                codec = s.get("codec_name", "?")
                print(f"    - [{lang}] {codec} {title}")

    return filepath


def check_already_dubbed(filepath, target_lang):
    """Check if the file already has a dubbed track for this language."""
    probe_cmd = [
        "ffprobe", "-v", "quiet", "-select_streams", "a",
        "-show_entries", "stream_tags=language,title",
        "-of", "json", filepath
    ]
    result = subprocess.run(probe_cmd, capture_output=True, text=True)
    if result.returncode == 0:
        probe = json.loads(result.stdout)
        for s in probe.get("streams", []):
            tags = s.get("tags", {})
            title = tags.get("title", "")
            if "AI Dubbed" in title and target_lang in (tags.get("language", ""), title):
                return True
    return False


def run_dubbing(input_file, target_lang, source_lang, hf_token, output_dir,
                tts_engine, device, nllb_model, whisper_model):
    """Run Open Dubbing on the movie."""
    log(f"Starting AI dubbing...")
    log(f"  Source: {source_lang} -> Target: {target_lang}")
    log(f"  TTS: {tts_engine} | Device: {device}")
    log(f"  NLLB model: {nllb_model} | Whisper: {whisper_model}")
    print()

    os.makedirs(output_dir, exist_ok=True)

    cmd = [
        "open-dubbing",
        "--input_file", input_file,
        "--target_language", target_lang,
        "--source_language", source_lang,
        "--hugging_face_token", hf_token,
        "--output_directory", output_dir,
        "--tts", tts_engine,
        "--device", device,
        "--nllb_model", nllb_model,
        "--whisper_model", whisper_model,
    ]

    # Set environment for Coqui TTS license acceptance
    env = os.environ.copy()
    env["COQUI_TOS_AGREED"] = "1"

    start_time = datetime.now()
    log(f"Processing started at {start_time.strftime('%H:%M:%S')}")
    log(f"Monitor GPU with: nvidia-smi -l 5  (in another terminal)")
    print()

    try:
        process = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, env=env,
        )
        for line in process.stdout:
            print(f"  {line}", end="")
        process.wait()

        elapsed = datetime.now() - start_time
        log(f"Processing took: {elapsed}")

        if process.returncode != 0:
            log(f"open-dubbing failed with code {process.returncode}", "ERROR")
            sys.exit(1)

    except KeyboardInterrupt:
        log("Interrupted! Partial output in: " + output_dir, "WARN")
        sys.exit(1)

    # Find dubbed output
    dubbed_file = None
    for pattern in ["*dubbed*", f"*{target_lang}*", "*.mp4"]:
        matches = list(Path(output_dir).rglob(pattern))
        for m in matches:
            if m.suffix in (".mp4", ".mkv") and m.name != os.path.basename(input_file):
                dubbed_file = str(m)
                break
        if dubbed_file:
            break

    if not dubbed_file:
        log("Could not find dubbed output!", "ERROR")
        log("Contents of output dir:")
        for f in Path(output_dir).rglob("*"):
            print(f"  {f}")
        sys.exit(1)

    log(f"Dubbed file: {dubbed_file}")
    return dubbed_file


def extract_audio(dubbed_file, output_audio):
    """Extract audio from dubbed video."""
    log("Extracting dubbed audio track...")
    cmd = [
        "ffmpeg", "-y", "-i", dubbed_file,
        "-vn", "-acodec", "aac", "-b:a", "192k",
        output_audio
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log(f"ffmpeg error: {result.stderr}", "ERROR")
        sys.exit(1)
    log(f"Audio extracted: {output_audio}")
    return output_audio


def count_audio_streams(filepath):
    """Count audio streams in a file."""
    cmd = [
        "ffprobe", "-v", "quiet", "-select_streams", "a",
        "-show_entries", "stream=index", "-of", "csv=p=0",
        filepath
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
    return len(lines)


def mux_audio(original_file, dubbed_audio, target_lang, lang_name):
    """Add dubbed audio track to the original file."""
    ext = Path(original_file).suffix.lower()
    temp_output = original_file + f".{target_lang}_temp{ext}"

    audio_idx = count_audio_streams(original_file)
    log(f"Muxing dubbed audio as track #{audio_idx + 1}...")

    if ext == ".mkv":
        cmd = [
            "mkvmerge", "-o", temp_output,
            original_file,
            "--language", f"0:{target_lang}",
            "--track-name", f"0:{lang_name} (AI Dubbed)",
            dubbed_audio
        ]
    else:
        cmd = [
            "ffmpeg", "-y",
            "-i", original_file,
            "-i", dubbed_audio,
            "-map", "0",
            "-map", "1:a",
            "-c", "copy",
            f"-metadata:s:a:{audio_idx}", f"language={target_lang}",
            f"-metadata:s:a:{audio_idx}", f"title={lang_name} (AI Dubbed)",
            temp_output
        ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log(f"Muxing failed: {result.stderr}", "ERROR")
        sys.exit(1)

    # Backup original and replace
    backup_path = original_file + ".pre_dub_backup"
    log(f"Backing up original -> {os.path.basename(backup_path)}")
    shutil.copy2(original_file, backup_path)

    log("Replacing original with dubbed version...")
    shutil.move(temp_output, original_file)
    log("Done! New audio track added to original file.")

    return original_file


def trigger_plex_scan(server, movie):
    """Tell Plex to rescan the library."""
    section = movie.section()
    log(f"Triggering Plex library scan: '{section.title}'...")
    section.update()
    log("Scan triggered - new audio track will appear shortly in Plex.")


# Language name lookup
LANG_NAMES = {
    "spa": "Spanish", "fra": "French", "deu": "German", "ita": "Italian",
    "por": "Portuguese", "rus": "Russian", "ara": "Arabic", "jpn": "Japanese",
    "kor": "Korean", "zho": "Chinese", "hin": "Hindi", "pol": "Polish",
    "tur": "Turkish", "nld": "Dutch", "ces": "Czech", "hun": "Hungarian",
    "heb": "Hebrew", "eng": "English",
}


def main():
    parser = argparse.ArgumentParser(
        description="Dub a Plex movie into another language using AI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Preview with voice cloning (Coqui XTTS v2):
  dubber --plex-url http://10.0.0.5:32400 \\
      --plex-token abc123 --hf-token hf_xxx \\
      --movie "The Matrix" --target-lang spa --tts coqui --no-mux

  # Full dub with generic voices (Edge TTS, more languages):
  dubber --plex-url http://10.0.0.5:32400 \\
      --plex-token abc123 --hf-token hf_xxx \\
      --movie "The Matrix" --target-lang heb --tts edge

Voice cloning languages (coqui): en, es, fr, de, it, pt, pl, tr, ru,
    nl, cs, ar, zh, hu, ko, ja, hi

Generic voice languages (edge): Hebrew + 60 more

Language codes: spa=Spanish, fra=French, deu=German, rus=Russian,
    ara=Arabic, jpn=Japanese, kor=Korean, heb=Hebrew, hin=Hindi
        """
    )

    parser.add_argument("--plex-url", required=True, help="Plex server URL")
    parser.add_argument("--plex-token", required=True, help="Plex token")
    parser.add_argument("--hf-token", required=True, help="HuggingFace token")
    parser.add_argument("--movie", required=True, help="Movie name to search in Plex")
    parser.add_argument("--movie-path", help="Override: direct path to movie file")
    parser.add_argument("--target-lang", default=DEFAULT_TARGET_LANG,
                        help=f"Target language ISO 639-3 (default: {DEFAULT_TARGET_LANG})")
    parser.add_argument("--source-lang", default=DEFAULT_SOURCE_LANG,
                        help=f"Source language ISO 639-3 (default: {DEFAULT_SOURCE_LANG})")
    parser.add_argument("--tts", default=DEFAULT_TTS, choices=["edge", "coqui", "mms", "openai"],
                        help=f"TTS engine (default: {DEFAULT_TTS})")
    parser.add_argument("--device", default=DEFAULT_DEVICE, choices=["cpu", "cuda"],
                        help=f"Compute device (default: {DEFAULT_DEVICE})")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help=f"Temp output directory (default: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--nllb-model", default="nllb-200-1.3B",
                        choices=["nllb-200-1.3B", "nllb-200-3.3B"],
                        help="Translation model (3.3B = better quality, more VRAM)")
    parser.add_argument("--whisper-model", default="medium",
                        choices=["medium", "large-v2", "large-v3"],
                        help="Whisper STT model (default: medium)")
    parser.add_argument("--no-mux", action="store_true",
                        help="Just produce dubbed file, don't modify original")
    parser.add_argument("--skip-checks", action="store_true",
                        help="Skip dependency checks")

    args = parser.parse_args()

    lang_name = LANG_NAMES.get(args.target_lang, args.target_lang.title())

    print(f"""
    ==================================================
         Plex AI Dubber - NAS Edition
         {args.source_lang.upper()} -> {lang_name} (Open Dubbing)
    ==================================================
    """)

    # Check deps
    if not args.skip_checks:
        gpu_available = check_dependencies()
        if args.device == "cuda" and not gpu_available:
            log("CUDA requested but no GPU found, falling back to CPU", "WARN")
            args.device = "cpu"

    # Connect to Plex
    server = connect_plex(args.plex_url, args.plex_token)
    movie = find_movie(server, args.movie)
    movie_file = get_movie_file(movie, args.movie_path)

    # Check if already dubbed
    if check_already_dubbed(movie_file, args.target_lang):
        log(f"This file already has an AI dubbed {args.target_lang} track!", "WARN")
        response = input("  Continue anyway? (y/N): ").strip().lower()
        if response != "y":
            sys.exit(0)

    # Run dubbing
    dubbed_file = run_dubbing(
        input_file=movie_file,
        target_lang=args.target_lang,
        source_lang=args.source_lang,
        hf_token=args.hf_token,
        output_dir=args.output_dir,
        tts_engine=args.tts,
        device=args.device,
        nllb_model=args.nllb_model,
        whisper_model=args.whisper_model,
    )

    if args.no_mux:
        log(f"Dubbed file ready at: {dubbed_file}")
        log("Play it with VLC to check quality before doing a full run.")
        return

    # Extract audio and mux into original
    dubbed_audio = os.path.join(args.output_dir, "dubbed_audio.aac")
    extract_audio(dubbed_file, dubbed_audio)
    mux_audio(movie_file, dubbed_audio, args.target_lang, lang_name)

    # Trigger Plex rescan
    trigger_plex_scan(server, movie)

    print(f"""
    ==================================================
                     ALL DONE!
    --------------------------------------------------
      {lang_name} audio track added to the movie.

      Open Plex -> Play the movie -> Click the
      audio icon -> Select "{lang_name} (AI Dubbed)"
    ==================================================
    """)


if __name__ == "__main__":
    main()
