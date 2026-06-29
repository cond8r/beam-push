#!/bin/bash
# Deploy Beam server to VPS
# Usage: bash deploy.sh [VPS_IP]

VPS="${1:-ubuntu@82.156.210.133}"
REMOTE_DIR="/opt/beam"

set -e
echo "==> Uploading to $VPS …"
ssh "$VPS" "mkdir -p $REMOTE_DIR"
scp server.py requirements.txt "$VPS:$REMOTE_DIR/"

echo "==> Installing Python dependencies …"
ssh "$VPS" "cd $REMOTE_DIR && pip3 install -r requirements.txt -q"

echo "==> Writing systemd service …"
ssh "$VPS" "cat > /etc/systemd/system/beam.service" << 'UNIT'
[Unit]
Description=Beam relay server
After=network.target

[Service]
WorkingDirectory=/opt/beam
ExecStart=/usr/bin/python3 -u server.py
Restart=always
RestartSec=5
Environment="BEAM_AUTH_TOKEN=42bb6684ae6c90d74e546c4bfa99976f"
Environment="BEAM_DB=/opt/beam/beam.db"
# iOS APNs — fill in after creating key in Apple Developer Portal:
#Environment="APNS_KEY_ID=XXXXXXXXXX"
#Environment="APNS_TEAM_ID=XXXXXXXXXX"
#Environment="APNS_KEY_P8=-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
#Environment="BEAM_BUNDLE_ID=com.fangduo.beam"
#Environment="APNS_PROD=1"
# Android FCM (v1 API) — put service account JSON path on server:
#Environment="FCM_SA_FILE=/opt/beam/firebase-sa.json"

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Starting Beam service …"
ssh "$VPS" "systemctl daemon-reload && systemctl enable beam && systemctl restart beam"
sleep 3
ssh "$VPS" "systemctl status beam --no-pager -l"

echo ""
echo "==> Opening firewall port 8899 …"
ssh "$VPS" "ufw allow 8899/tcp 2>/dev/null || firewall-cmd --permanent --add-port=8899/tcp && firewall-cmd --reload 2>/dev/null || iptables -I INPUT -p tcp --dport 8899 -j ACCEPT 2>/dev/null; echo 'firewall done'"

echo ""
echo "✓ Deploy complete."
echo "  Test: curl http://82.156.210.133:8899/health"
