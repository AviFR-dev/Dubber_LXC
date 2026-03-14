#!/bin/bash
# Install the Label Watcher daemon — run inside dubber LXC
echo "  Installing Label Watcher..."
cp /root/dubber_watcher.py /opt/dubber/scripts/dubber_watcher.py
cp /root/dubber-watcher.service /etc/systemd/system/dubber-watcher.service
if [ ! -f /opt/dubber/config.json ]; then
    cat > /opt/dubber/config.json << 'EOF'
{
  "plex_url": "http://PLEX_IP:32400",
  "plex_token": "YOUR_PLEX_TOKEN",
  "hf_token": "hf_YOUR_TOKEN",
  "target_languages": {"spanish": "spa", "french": "fra", "german": "deu"},
  "source_language": "eng",
  "tts_engine": "coqui",
  "device": "cpu",
  "whisper_model": "medium",
  "nllb_model": "nllb-200-1.3B",
  "scan_interval": 120,
  "output_dir": "/opt/dubber/output"
}
EOF
    echo "  Config: /opt/dubber/config.json (EDIT WITH YOUR TOKENS)"
fi
systemctl daemon-reload && systemctl enable dubber-watcher
echo ""
echo "  Next: nano /opt/dubber/config.json"
echo "  Then: systemctl start dubber-watcher"
echo "  Logs: journalctl -u dubber-watcher -f"
echo "  In Plex: add label 'dub-spanish' to any movie!"
