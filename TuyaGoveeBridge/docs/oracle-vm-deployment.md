# Deploying TuyaGoveeBridge to an Oracle Cloud Always Free VM

Oracle's Always Free tier includes a small ARM (Ampere A1) VM that never expires and is
never billed as long as you stay within the free-tier shape/limits. This gives the bridge a
real always-on host without buying hardware or paying a subscription.

## 1. Create the Oracle Cloud account and VM

1. Sign up at cloud.oracle.com. Oracle asks for a card for identity verification, but the
   Always Free resources themselves aren't charged.
2. In the console, go to **Compute → Instances → Create Instance**.
3. Choose an **Ampere A1 (arm)** shape — the free tier gives you up to 4 OCPUs / 24 GB RAM
   total across your Ampere instances; one small instance (e.g. 1 OCPU / 6 GB) is plenty for
   this service.
4. Choose a **Canonical Ubuntu** image (22.04 or 24.04 LTS).
5. Under **Add SSH keys**, either upload your own public key or let Oracle generate a key
   pair and download the private key — you'll need it to SSH in.
6. Create the instance and note its public IP address once it's running.

## 2. Connect and install the .NET runtime

```bash
ssh -i /path/to/your-key.pem ubuntu@<vm-public-ip>
```

Then, on the VM:

```bash
sudo apt-get update
sudo apt-get install -y dotnet-runtime-10.0
```

(If that package name isn't available yet for your Ubuntu release, follow Microsoft's
`dotnet-install.sh` script instructions instead — it installs a self-contained runtime under
your home directory without needing a distro package.)

## 3. Build and copy the app from your Mac

From the repo root, targeting the VM's architecture (Ampere = arm64):

```bash
dotnet publish TuyaGoveeBridge/TuyaGoveeBridge -c Release -r linux-arm64 --self-contained false -o publish
```

Fill in `TuyaGoveeBridge/TuyaGoveeBridge/appsettings.Local.json` with your real Tuya/Govee
credentials and button mappings (see the project README) before copying, then copy everything
over:

```bash
scp -i /path/to/your-key.pem -r publish ubuntu@<vm-public-ip>:/home/ubuntu/tuya-govee-bridge
```

## 4. Run it as a systemd service

On the VM, create `/etc/systemd/system/tuya-govee-bridge.service`:

```ini
[Unit]
Description=Tuya button to Govee light bridge
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/home/ubuntu/tuya-govee-bridge
ExecStart=/usr/bin/dotnet /home/ubuntu/tuya-govee-bridge/TuyaGoveeBridge.dll
Restart=always
RestartSec=5
User=ubuntu
Environment=DOTNET_ENVIRONMENT=Production

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tuya-govee-bridge
sudo journalctl -u tuya-govee-bridge -f
```

The `journalctl -f` tail is where you'll see the "Tuya button 'xxx' reported status: ..." log
lines the first time you press a button — that's what's needed to confirm the connection works
and to figure out the exact press payload if the trigger needs narrowing later.

## 5. Redeploying after a code change

Repeat step 3's `dotnet publish` + `scp`, then on the VM:

```bash
sudo systemctl restart tuya-govee-bridge
```

## Firewall note

This service only makes outbound connections (to Tuya's Pulsar endpoint and Govee's API) — it
doesn't listen for inbound traffic, so no Oracle security-list/VCN ingress rule changes are
needed for it to work.
