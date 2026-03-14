# Plex AI Dubber

**Author: Avi Fridlindas**

Automatically dub movies and TV shows in your Plex library into other languages using open-source AI models with voice cloning. Runs on a dedicated Proxmox LXC container.

## How It Works

```
┌─────────────┐     ┌─────────────────┐     ┌─────────┐
│  Plex LXC   │────▶│  Dubber LXC     │────▶│   NAS   │
│  (player)   │     │  (AI processing) │     │ (media) │
└─────────────┘     └─────────────────┘     └─────────┘
```

### AI Pipeline

```
Movie File
    │
    ▼
┌──────────────┐
│ Audio Extract │  FFmpeg — extract audio track
│ + Demucs     │  Separate vocals from music/effects (CPU)
└──────┬───────┘
       ▼
┌──────────────┐
│ Speaker      │  pyannote — identify who speaks when
│ Diarization  │
└──────┬───────┘
       ▼
┌──────────────┐
│ Speech to    │  Whisper — transcribe dialog
│ Text (STT)   │
└──────┬───────┘
       ▼
┌──────────────┐
│ Translation  │  Meta NLLB-200 — translate to target language
└──────┬───────┘
       ▼
┌──────────────┐
│ Voice Clone  │  Coqui XTTS v2 — clone original actor's voice
│ + TTS        │  OR Edge TTS — generic but supports more languages
└──────┬───────┘
       ▼
┌──────────────┐
│ Audio Sync   │  Match timing + mux as new track
│ + Mux        │  Plex sees it as selectable audio
└──────────────┘
```

## Features

- **Voice Cloning** — Coqui XTTS v2 clones the original actor's voice (17 languages)
- **Open Source** — built on [Open Dubbing](https://github.com/Softcatala/open-dubbing)
- **Plex Integrated** — searches library, muxes audio, triggers rescan
- **Label Watcher** — add "dub-spanish" label in Plex → auto-dubs in background
- **NAS Friendly** — designed for media on network shares
- **Auto-Detection** — setup script detects GPU, drivers, storage, mounts
- **Safe** — creates backups, `--no-mux` for previewing

## Requirements

- **Proxmox VE** 7.x or 8.x 9.x
- **NVIDIA GPU** with drivers on host (CPU fallback available)
- **12+ GB VRAM recommended** for GPU mode (RTX 3060+)
- **6 GB VRAM** works but runs on CPU (GTX 1060 etc.)
- **NFS/CIFS share** or local storage with media
- **HuggingFace account** (free) for speaker diarization models

### Recommended LXC Specs

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM      | 6 GB    | 8 GB        |
| CPU      | 2 cores | 4 cores     |
| Disk     | 30 GB   | 50 GB       |
| GPU VRAM | 6 GB (CPU mode) | 12+ GB (full GPU) |

## Quick Start

### 1. Clone and run the installer

```bash
# On your Proxmox host
git clone https://github.com/AviFR-dev/Dubber_LXC.git
cd Dubber_LXC
bash setup_dubber_lxc.sh
```

### 2. Get your tokens

**Plex Token:** [Finding your Plex Token](https://support.plex.tv/articles/204059436)

**HuggingFace Token (free):**
1. Create account at [huggingface.co](https://huggingface.co)
2. Accept model licenses:
   - [pyannote/segmentation-3.0](https://hf.co/pyannote/segmentation-3.0)
   - [pyannote/speaker-diarization-3.1](https://hf.co/pyannote/speaker-diarization-3.1)
3. Create token at [hf.co/settings/tokens](https://hf.co/settings/tokens) (Read access)

### 3. Test dub a movie

```bash
pct enter <DUBBER_CTID>

dubber \
  --plex-url http://PLEX_IP:32400 \
  --plex-token YOUR_PLEX_TOKEN \
  --hf-token hf_YOUR_TOKEN \
  --movie "Movie Name" \
  --target-lang spa \
  --tts coqui \
  --no-mux
```

### 4. Set up auto-dubbing via labels (optional)

```bash
bash /root/install_watcher.sh
nano /opt/dubber/config.json    # Add your tokens
systemctl start dubber-watcher
```

Then in Plex: any movie → Edit → Tags → add label **`dub-spanish`**

## TTS Engines

| Engine | Voice Quality | Clones Voice? | Languages | GPU VRAM |
|--------|-------------|---------------|-----------|----------|
| `coqui` | Good — sounds like original actor | **Yes** | 17 | 12+ GB or CPU |
| `edge` | Decent — generic Microsoft voices | No | 60+ | None (cloud) |

### Coqui XTTS v2 Languages (voice cloning)
English, Spanish, French, German, Italian, Portuguese, Polish, Turkish, Russian, Dutch, Czech, Arabic, Chinese, Hungarian, Korean, Japanese, Hindi

### Edge TTS Languages (no cloning, but more languages)
Hebrew, Arabic, and 60+ others

## Usage

```
dubber --help

Options:
  --plex-url        Plex server URL
  --plex-token      Plex authentication token
  --hf-token        HuggingFace API token
  --movie           Movie name to search in Plex
  --movie-path      Direct path to movie file (overrides Plex)
  --target-lang     Target language ISO 639-3 (default: spa)
  --source-lang     Source language ISO 639-3 (default: eng)
  --tts             TTS engine: coqui, edge, mms, openai (default: coqui)
  --device          Compute device: cuda, cpu (default: cpu)
  --nllb-model      Translation model: nllb-200-1.3B, nllb-200-3.3B
  --whisper-model   STT model: medium, large-v2, large-v3 (default: medium)
  --no-mux          Only produce dubbed file, don't modify original
  --skip-checks     Skip dependency verification
```

## Label Watcher (Auto-Dubbing)

The watcher daemon monitors your Plex library for labeled movies:

| You Add Label | Watcher Changes To | When Done |
|---------------|-------------------|-----------|
| `dub-spanish` | `dubbing-spanish` | `dubbed-spanish` |
| `dub-french`  | `dubbing-french`  | `dubbed-french`  |
| `dub-german`  | `dubbing-german`  | `dubbed-german`  |

If dubbing fails: `dub-failed-spanish`

```bash
# Monitor the watcher
journalctl -u dubber-watcher -f

# Check status
systemctl status dubber-watcher
```

## Language Codes

| Code | Language   | Code | Language    | Code | Language   |
|------|-----------|------|------------|------|-----------|
| spa  | Spanish   | fra  | French     | deu  | German    |
| rus  | Russian   | ara  | Arabic     | jpn  | Japanese  |
| kor  | Korean    | zho  | Chinese    | hin  | Hindi     |
| ita  | Italian   | por  | Portuguese | pol  | Polish    |
| tur  | Turkish   | nld  | Dutch      | ces  | Czech     |
| hun  | Hungarian | heb  | Hebrew*    | eng  | English   |

*Hebrew only with Edge TTS (no voice cloning)

## GPU Compatibility

| GPU | VRAM | Mode | Performance |
|-----|------|------|-------------|
| RTX 4090/4080 | 16-24 GB | Full CUDA | Fast — all models on GPU |
| RTX 3060/3070 | 12 GB | Full CUDA | Good — recommended minimum |
| GTX 1060/1070 | 6-8 GB | CPU mode | Works but slower (VRAM too small) |
| No GPU | — | CPU only | Slowest but functional |

## Troubleshooting

**LXC won't start**
- Mount issue → remove `mp` lines from `/etc/pve/lxc/<CTID>.conf`
- GPU missing → run `nvidia-smi` on Proxmox host first

**"Utterances: 0" — no speech detected**
- cuDNN issue — Whisper must run on CPU in LXC environments
- The setup script patches this automatically

**CUDA out of memory**
- Use `--device cpu` for GPUs with < 12GB VRAM
- Or use `--tts edge` instead of `--tts coqui` (Edge doesn't use GPU)

**Open Dubbing renames files**
- It strips special characters from filenames
- Use `--movie-path` to specify exact file path

**Demucs OOM (exit code 137)**
- Setup script forces Demucs to CPU automatically
- This is normal for 6GB GPUs

## File Structure

```
/opt/dubber/
├── bin/                    # Python venv binaries
├── scripts/
│   ├── plex_ai_dubber.py  # Main dubber script
│   └── dubber_watcher.py  # Label watcher daemon
├── config.json             # Watcher configuration
├── output/                 # Temporary processing files
└── watcher.log            # Watcher daemon log
```

## Credits

Built on these open-source projects:
- [Open Dubbing](https://github.com/Softcatala/open-dubbing) — core dubbing engine
- [Coqui XTTS v2](https://huggingface.co/coqui/XTTS-v2) — voice cloning
- [Whisper](https://github.com/openai/whisper) / [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — speech recognition
- [NLLB-200](https://github.com/facebookresearch/fairseq/tree/nllb) — translation
- [pyannote-audio](https://github.com/pyannote/pyannote-audio) — speaker diarization
- [demucs](https://github.com/adefossez/demucs) — audio source separation
- [PlexAPI](https://github.com/pkkid/python-plexapi) — Plex integration

## Legal Notice

This project provides scripts for personal, non-commercial use. The AI models downloaded during setup have their own licenses:

- **Coqui XTTS v2**: [CPML](https://coqui.ai/cpml) — non-commercial use only
- **Meta NLLB-200**: CC-BY-NC-4.0 — non-commercial use only
- **pyannote models**: MIT — requires accepting terms on HuggingFace
- **OpenAI Whisper / faster-whisper**: MIT
- **Demucs**: MIT

Users are responsible for complying with applicable model licenses and copyright laws in their jurisdiction. This tool is intended for dubbing media you personally own for personal viewing. Do not use this tool to dub or distribute copyrighted content you do not own.

## License

MIT — Created by **Avi Fridlindas**
