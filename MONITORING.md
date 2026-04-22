# Proxmox Monitoring Stack

Full observability stack for the Proxmox homelab: GPU metrics, host metrics, and Proxmox hypervisor metrics — all visualized in Grafana.

---

## Architecture

```
VM 104 (192.168.0.87) — arthur-server2
├── nvidia_gpu_exporter  :9835  → RTX 5060 Ti metrics via nvidia-smi
├── prometheus-node-exporter :9100  → CPU / RAM / disk / network
├── prometheus           :9090  → Scrapes all targets, stores TSDB
└── grafana              :3000  → Dashboards

Proxmox host (192.168.0.153)
└── pve_exporter         :9221  → PVE API metrics (VMs, storage, nodes)
```

Prometheus on VM 104 scrapes:
| Job | Target | What it collects |
|-----|--------|-----------------|
| `nvidia_gpu` | `localhost:9835` | GPU util, VRAM, temp, power, clocks, fan |
| `node` | `localhost:9100` | CPU, RAM, disk I/O, network, uptime |
| `prometheus` | `localhost:9090` | Prometheus self-metrics |
| `proxmox` | `192.168.0.153:9221` | VMs status, storage, PVE node health |

---

## Component Versions

| Component | Version | Host |
|-----------|---------|------|
| nvidia-gpu-exporter | 1.4.1 | VM 104 |
| prometheus | 2.31.2 | VM 104 |
| prometheus-node-exporter | (apt) | VM 104 |
| grafana | 13.0.1 | VM 104 |
| prometheus-pve-exporter | 3.8.2 | Proxmox |

---

## Installation

### VM 104 — nvidia_gpu_exporter

```bash
# Download and install .deb (v1.4.1 switched from tar.gz to .deb packaging)
wget -O /tmp/nge.deb \
  https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v1.4.1/nvidia-gpu-exporter_1.4.1_linux_amd64.deb
dpkg -i /tmp/nge.deb

# Service is auto-enabled by the .deb postinst
systemctl enable --now nvidia_gpu_exporter
systemctl status nvidia_gpu_exporter
```

Service unit at `/lib/systemd/system/nvidia_gpu_exporter.service`:
```ini
[Unit]
Description=Nvidia GPU Exporter
After=network-online.target

[Service]
Type=simple
User=nvidia_gpu_exporter
Group=nvidia_gpu_exporter
ExecStart=/usr/bin/nvidia_gpu_exporter
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

Verify:
```bash
curl http://localhost:9835/metrics | grep nvidia_smi_gpu_info
```

---

### VM 104 — Prometheus + Node Exporter

```bash
apt-get update
apt-get install -y prometheus prometheus-node-exporter
```

Write `/etc/prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'nvidia_gpu'
    static_configs:
      - targets: ['localhost:9835']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'proxmox'
    static_configs:
      - targets: ['192.168.0.153:9221']
    metrics_path: /pve
    params:
      module: [default]
```

```bash
systemctl enable --now prometheus prometheus-node-exporter

# Verify targets are all up
curl -s http://localhost:9090/api/v1/label/job/values
# Expected: {"status":"success","data":["node","nvidia_gpu","prometheus","proxmox"]}
```

> **Important:** If Prometheus was started before the config was fully written, restart it:
> ```bash
> systemctl restart prometheus
> ```

---

### VM 104 — Grafana

```bash
# Add Grafana apt repo
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana

systemctl enable --now grafana-server
```

**Reset admin password** (required on first install — default `admin/admin` is rejected by API):
```bash
grafana cli --homepath /usr/share/grafana admin reset-admin-password admin123
systemctl restart grafana-server
```

---

### Proxmox Host — pve_exporter

```bash
# Install Python venv + pip
apt-get install -y python3-venv python3-pip
python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install prometheus-pve-exporter==3.8.2

# Create PVE monitoring user (read-only)
pveum user add monitoring@pve --comment "Prometheus scrape user"
pveum aclmod / -user monitoring@pve -role PVEAuditor
TOKEN=$(pveum user token add monitoring@pve prometheus --privsep 0 --output-format json | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
echo "Token: $TOKEN"

# Write config
mkdir -p /etc/pve_exporter
cat > /etc/pve_exporter/pve.yml << EOF
default:
  user: monitoring@pve
  token_name: prometheus
  token_value: ${TOKEN}
  verify_ssl: false
EOF
chmod 600 /etc/pve_exporter/pve.yml
```

Write `/etc/systemd/system/pve_exporter.service`:
```ini
[Unit]
Description=Prometheus PVE Exporter
After=network.target pvedaemon.service

[Service]
Type=simple
ExecStart=/opt/pve-exporter/bin/pve_exporter \
  --config.file=/etc/pve_exporter/pve.yml \
  --web.listen-address=0.0.0.0:9221
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

> **Note:** pve_exporter v3.x changed CLI — positional args were removed. Must use `--config.file=` and `--web.listen-address=` flags.

```bash
systemctl daemon-reload
systemctl enable --now pve_exporter

# Verify
curl -s "http://localhost:9221/pve?target=localhost&module=default" | grep pve_up
# Expected: pve_up{id="node/prox"} 1.0
```

---

## Grafana Dashboards

Grafana URL: **http://192.168.0.87:3000**  
Login: `admin` / `admin123`

### Automated import via API

```bash
DS_UID=$(curl -s http://admin:admin123@localhost:3000/api/datasources/name/Prometheus \
  | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)

# Import a dashboard from grafana.com (use temp file for large JSON)
DASH_ID=14574  # change as needed
curl -s https://grafana.com/api/dashboards/${DASH_ID}/revisions/latest/download > /tmp/dash.json
python3 - << EOF
import json
d = json.load(open('/tmp/dash.json'))
payload = json.dumps({
    'dashboard': d,
    'overwrite': True,
    'inputs': [{'name': 'DS_PROMETHEUS', 'type': 'datasource', 'pluginId': 'prometheus', 'value': '$DS_UID'}],
    'folderId': 0
})
open('/tmp/import.json', 'w').write(payload)
EOF
curl -s -X POST http://admin:admin123@localhost:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d @/tmp/import.json | grep -o '"importedUrl":"[^"]*"'
```

### Imported dashboards

| Dashboard | Grafana ID | URL path | What it shows |
|-----------|-----------|----------|---------------|
| NVIDIA GPU Metrics | 14574 | `/d/vlvPlrgnk/nvidia-gpu-metrics` | Utilization, VRAM, temp, power, clocks, fan |
| Node Exporter Full | 1860 | `/d/rYdddlPWk/node-exporter-full` | CPU, RAM, disk I/O, network, load |
| Proxmox via Prometheus | 10347 | `/d/Dp7Cd57Zza/proxmox-via-prometheus` | VMs, storage pools, node health |

### Add Prometheus datasource

```bash
curl -s -X POST http://admin:admin123@localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://localhost:9090",
    "access": "proxy",
    "isDefault": true
  }'
```

---

## Service Management

All commands run on **VM 104** (`ssh root@192.168.0.87`) unless noted.

### Status check (all at once)

```bash
systemctl is-active nvidia_gpu_exporter prometheus-node-exporter prometheus grafana-server
```

### Restart all

```bash
systemctl restart nvidia_gpu_exporter prometheus-node-exporter prometheus grafana-server
```

### Check Prometheus targets

```bash
# List all active jobs
curl -s http://localhost:9090/api/v1/label/job/values

# Check target health (up/down + last error)
curl -s http://localhost:9090/api/v1/targets | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(t['labels']['job'], t['health'], t.get('lastError','')[:60])
"
```

### Query GPU metrics directly

```bash
# Current GPU utilization
curl -s 'http://localhost:9090/api/v1/query?query=nvidia_smi_utilization_gpu_ratio'

# Current GPU temperature
curl -s 'http://localhost:9090/api/v1/query?query=nvidia_smi_temperature_gpu'

# VRAM used / total
curl -s 'http://localhost:9090/api/v1/query?query=nvidia_smi_memory_used_bytes/nvidia_smi_memory_total_bytes'
```

### Raw exporter endpoints

```bash
# GPU exporter (all nvidia_smi_* metrics)
curl http://192.168.0.87:9835/metrics | grep nvidia_smi

# Node exporter
curl http://192.168.0.87:9100/metrics | grep node_cpu

# Prometheus health
curl http://192.168.0.87:9090/-/healthy

# pve_exporter (on Proxmox host)
curl "http://192.168.0.153:9221/pve?target=localhost&module=default" | grep pve_up
```

### pve_exporter (run on Proxmox host — `ssh root@192.168.0.153`)

```bash
systemctl status pve_exporter
journalctl -u pve_exporter -n 30
systemctl restart pve_exporter
```

---

## Credentials & Config Files

| File | Host | Purpose |
|------|------|---------|
| `/etc/prometheus/prometheus.yml` | VM 104 | Scrape targets |
| `/lib/systemd/system/nvidia_gpu_exporter.service` | VM 104 | GPU exporter unit |
| `/etc/grafana/grafana.ini` | VM 104 | Grafana config |
| `/etc/pve_exporter/pve.yml` | Proxmox | PVE API token |
| `/etc/systemd/system/pve_exporter.service` | Proxmox | pve_exporter unit |

**PVE monitoring account:**
- User: `monitoring@pve`
- Token name: `prometheus`
- Token value: `4ec33deb-28e4-473c-98fc-4409caf8d132`
- Role: `PVEAuditor` on `/`

**Grafana:**
- URL: http://192.168.0.87:3000
- User: `admin`
- Password: `admin123`

---

## Troubleshooting

### GPU metrics empty in Grafana

Dashboard variables populate from `nvidia_smi_index`. If the `nvidia_gpu` job never scraped, Prometheus TSDB has no data and the dropdowns are blank.

```bash
# Check if nvidia_gpu job is active
curl -s http://localhost:9090/api/v1/label/job/values
# If nvidia_gpu is missing, restart Prometheus (it may have started before config was written)
systemctl restart prometheus
sleep 10
curl -s http://localhost:9090/api/v1/label/job/values
# Should now include nvidia_gpu
```

### pve_exporter failing to start

v3.x removed positional arguments. The unit file **must** use named flags:
```
ExecStart=... --config.file=/etc/pve_exporter/pve.yml --web.listen-address=0.0.0.0:9221
```
Old-style `pve_exporter /etc/pve_exporter/pve.yml 9221 0.0.0.0` will fail with exit code 2.

### Grafana API returns "Invalid username or password"

On a fresh install, Grafana rejects the default `admin/admin` via API (forces browser change).  
Fix:
```bash
grafana cli --homepath /usr/share/grafana admin reset-admin-password admin123
systemctl restart grafana-server
```

### Prometheus only shows 2 of 4 jobs after install

Prometheus can start before the config write completes. Always restart after writing the config:
```bash
systemctl restart prometheus
```

### nvidia_gpu_exporter 404 on download

v1.4.1 changed packaging from `.tar.gz` to `.deb`. Use the `.deb` URL:
```
https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v1.4.1/nvidia-gpu-exporter_1.4.1_linux_amd64.deb
```

---

## Key Metrics Reference

| Metric | Description |
|--------|-------------|
| `nvidia_smi_utilization_gpu_ratio` | GPU core utilization (0–1) |
| `nvidia_smi_utilization_memory_ratio` | GPU memory controller utilization (0–1) |
| `nvidia_smi_memory_used_bytes` | VRAM used in bytes |
| `nvidia_smi_memory_total_bytes` | Total VRAM in bytes |
| `nvidia_smi_temperature_gpu` | GPU die temperature (°C) |
| `nvidia_smi_power_draw_watts` | Current power draw (W) |
| `nvidia_smi_power_default_limit_watts` | TDP limit (W) |
| `nvidia_smi_fan_speed_ratio` | Fan speed (0–1) |
| `nvidia_smi_clocks_current_graphics_clock_hz` | Current core clock (Hz) |
| `nvidia_smi_clocks_current_memory_clock_hz` | Current memory clock (Hz) |
| `pve_up` | Proxmox node/VM/CT online status |
| `node_cpu_seconds_total` | CPU time by mode |
| `node_memory_MemAvailable_bytes` | Available RAM |
| `node_filesystem_avail_bytes` | Disk free space |
