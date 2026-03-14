#!/bin/bash
#================================================================
# Plex AI Dubber — Post-Install Patches
# Author: Avi Fridlindas
#
# Run inside the dubber LXC after setup_dubber_lxc.sh completes.
# Fixes all known compatibility issues:
#   1. Demucs forced to CPU (prevents GPU OOM)
#   2. Whisper forced to CPU (cuDNN not available in LXC)
#   3. Whisper compute_type set to float32 (GTX 10xx compat)
#   4. Coqui TTS API compatibility fix
#   5. matplotlib missing dependency
#   6. nvidia-smi and dubber command setup
#
# Usage:
#   bash apply_patches.sh
#================================================================

set -uo pipefail

echo ""
echo "  Plex AI Dubber — Applying Patches"
echo ""

source /opt/dubber/bin/activate

# ─── Patch 1: Fix nvidia-smi ───
echo "[1/6] Fixing nvidia-smi..."
if [ -f /opt/nvidia-libs/nvidia-smi ]; then
    cp /opt/nvidia-libs/nvidia-smi /usr/bin/nvidia-smi 2>/dev/null || true
    chmod +x /usr/bin/nvidia-smi 2>/dev/null || true
    echo "  Done."
else
    echo "  Skipped (no GPU libs found)."
fi

# ─── Patch 2: Fix dubber command ───
echo "[2/6] Fixing dubber command..."
cat > /usr/bin/dubber << 'EOF'
#!/bin/bash
source /opt/dubber/bin/activate
export COQUI_TOS_AGREED=1
export LD_LIBRARY_PATH=/opt/nvidia-libs:${LD_LIBRARY_PATH:-}
python /opt/dubber/scripts/plex_ai_dubber.py "$@"
EOF
chmod +x /usr/bin/dubber
echo "  Done."

# ─── Patch 3: Install missing dependencies ───
echo "[3/6] Installing missing Python packages..."
pip install --quiet matplotlib TTS nvidia-cudnn-cu12 2>&1 | tail -3
echo "  Done."

# ─── Patch 4: Force Demucs to CPU (prevents OOM on < 12GB GPUs) ───
echo "[4/6] Patching Demucs to use CPU..."
DEMUCS_FILE="/opt/dubber/lib/python3.11/site-packages/open_dubbing/demucs.py"
if [ -f "$DEMUCS_FILE" ]; then
    sed -i 's/--device cuda/--device cpu/' "$DEMUCS_FILE"
    echo "  Done."
else
    echo "  Skipped (file not found)."
fi

# ─── Patch 5: Force Whisper to CPU + float32 ───
echo "[5/6] Patching Whisper STT for LXC compatibility..."
STT_FILE="/opt/dubber/lib/python3.11/site-packages/open_dubbing/speech_to_text_faster_whisper.py"
if [ -f "$STT_FILE" ]; then
    # Force CPU for Whisper (cuDNN not available in LXC bind-mount setup)
    sed -i 's/device=self\.device,/device="cpu",/' "$STT_FILE"
    # Force float32 compute type (compatible with all GPUs and CPU)
    sed -i 's/compute_type="float16"/compute_type="float32"/' "$STT_FILE"
    # Fix any conditional compute_type
    sed -i 's/compute_type="float32" if self\.device == "cuda" else "int8"/compute_type="float32"/' "$STT_FILE"
    echo "  Done."
else
    echo "  Skipped (file not found)."
fi

# ─── Patch 6: Fix Coqui TTS API compatibility ───
echo "[6/6] Patching Coqui TTS API..."
COQUI_FILE="/opt/dubber/lib/python3.11/site-packages/open_dubbing/coqui.py"
if [ -f "$COQUI_FILE" ]; then
    # Fix TTS.list_models() → TTS().list_models().list_models()
    sed -i 's/for model in TTS\.list_models():/for model in TTS().list_models().list_models():/' "$COQUI_FILE"
    # In case it was already partially patched
    sed -i 's/for model in TTS()\.list_models():/for model in TTS().list_models().list_models():/' "$COQUI_FILE"
    # Prevent double-patching
    sed -i 's/TTS()\.list_models()\.list_models()\.list_models()/TTS().list_models().list_models()/' "$COQUI_FILE"
    echo "  Done."
else
    echo "  Skipped (file not found)."
fi

# ─── Set environment permanently ───
echo ""
echo "  Setting environment variables..."
grep -q "COQUI_TOS_AGREED" /root/.bashrc || echo 'export COQUI_TOS_AGREED=1' >> /root/.bashrc
grep -q "nvidia-libs" /root/.bashrc || echo 'export LD_LIBRARY_PATH=/opt/nvidia-libs:${LD_LIBRARY_PATH:-}' >> /root/.bashrc

# ─── Verify ───
echo ""
echo "  Verifying..."
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null && echo "  GPU: OK" || echo "  GPU: Not available (CPU mode)"
dubber --help > /dev/null 2>&1 && echo "  dubber: OK" || echo "  dubber: ISSUE"
python3 -c "import TTS; print('  Coqui TTS: OK')" 2>/dev/null || echo "  Coqui TTS: Not installed"
python3 -c "import matplotlib; print('  matplotlib: OK')" 2>/dev/null || echo "  matplotlib: Not installed"

echo ""
echo "  All patches applied!"
echo ""
echo "  Usage:"
echo "    dubber --movie \"Movie Name\" --plex-url http://IP:32400 \\"
echo "      --plex-token TOKEN --hf-token hf_TOKEN \\"
echo "      --target-lang spa --tts coqui --no-mux"
echo ""
