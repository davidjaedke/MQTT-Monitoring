# MQTT Server Monitoring for Home Assistant (Bash)

A tiny, cron-friendly Bash script that turns your Linux server into a set of **auto-discovered Home Assistant sensors** via MQTT.  
It reads common system metrics (CPU, RAM, disks, temps, ZFS, processes, network throughput, updates…) and publishes them using **MQTT Discovery**—no manual HA config needed.


---

## ✨ Features

- **Home Assistant MQTT Discovery** (retained) – sensors appear automatically
- **CPU & RAM** (incl. % used)
- **Disks** – per mount: used %, used/total MB
- **Temperatures** – hwmon (CPU/package/board/RAM), **SMART (SSD/HDD)**  
  ↳ **`--vm`** flag to skip temps on virtual machines
- **ZFS**
  - Pool **health**
  - **IOPS & Bandwidth (MB/s)** per pool as a moment snapshot
- **Network throughput (MB/s)**
  - **Average** between cron runs
  - **Instant snapshot**: read counters, wait 2s, read again
- **Processes** (like `top`) – **separate sensors**: total, running, sleeping, stopped, zombie, uninterruptible (D)
- **CPU iowait %** (instant snapshot)
- **APT updates** available (Debian/Ubuntu)
- **Uptime** and **Last Run** (human-readable `YYYY-MM-DD HH:MM:SS`)
- Clean **`--info`** CLI view (pretty printed), **`--debug`** tracing
- **dependency checks** + cron-safe `PATH`

---

## 📦 Installation

```bash
# 1) Get the script
sudo curl -L -o /usr/local/bin/ha-mqtt-server-monitor https://raw.githubusercontent.com/davidjaedke/MQTT-Monitoring/refs/heads/main/ha-mqtt-server-monitor.sh
sudo chmod +x /usr/local/bin/ha-mqtt-server-monitor

# 2) Install dependencies
sudo apt-get update
# Required:
sudo apt-get install -y mosquitto-clients
# Optional (enable extra metrics):
sudo apt-get install -y zfsutils-linux smartmontools
```

> The script also uses standard base tools (`awk`, `sed`, `grep`, `df`, `lsblk`, `hostname`, `date`, `sleep`) which are present on most systems.

---

## ⚙️ Configuration

Open the top of the script and adjust:

```bash
MQTT_HOST="127.0.0.1"
MQTT_PORT="1883"
MQTT_USER=""           # optional
MQTT_PASS=""           # optional
MQTT_TLS=""            # e.g. "--cafile /etc/ssl/certs/ca-certificates.crt" (or leave empty)

DISCOVERY_PREFIX="homeassistant"
DEVICE_NAME="$(hostname)"
DEVICE_ID="<auto>"     # derived from hostname (lowercased, sanitized)

ROOT_TOPIC="servers/${DEVICE_ID}"
STATE_PREFIX="${ROOT_TOPIC}/state"

BYTES_PER_MB=1000000   # set to 1048576 for MiB/s if you prefer
STATE_FILE="/var/tmp/ha_mqtt_mon.state"

INSTANT_INTERVAL_SEC=2 # snapshot interval for network/ZFS/CPU iowait
```

**Security tip:** if you set username/password, prefer enabling TLS (`MQTT_TLS="--cafile /path/to/ca.crt"`).

---

## 🚀 Usage

```bash
# One-off test with pretty output
ha-mqtt-server-monitor --info

# Extra logs (what it does, step by step)
ha-mqtt-server-monitor --info --debug

# On virtual machines (skips hardware temps/SMART)
ha-mqtt-server-monitor --vm --info
```

### Cron (recommended)

Run as **root** every minute:

```bash
sudo crontab -e
# add:
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * /usr/local/bin/ha-mqtt-server-monitor
```

## 🧭 MQTT & Discovery

- **Discovery topics** (retained):  
  `homeassistant/sensor/<device_id>_<sensor_id>/config`
- **State topics** (retained):  
  `servers/<device_id>/state/<sensor_id>`

Each sensor has a stable `unique_id` (based on `DEVICE_ID` + sensor id), so HA entities keep their history across restarts.

---

## 📊 Metrics & Sensors

Below is a non-exhaustive list (sensor ids are shown in `code`):

### CPU & Memory
- CPU load 1m: `cpu_load_1m`
- RAM used MB: `ram_used_mb`  
- RAM total MB: `ram_total_mb`  
- RAM used %: `ram_used_percent`

### Disks (per mount)
- Used %: `disk_<mount>_used_percent`
- Used MB: `disk_<mount>_used_mb`
- Total MB: `disk_<mount>_total_mb`

> Excludes ephemeral filesystems (tmpfs, devtmpfs, squashfs, overlay, zram, udf, iso9660, ramfs).

### Temperatures (bare metal only; skipped with `--vm`)
- HWMon sensors: `temp_<chip>_<label>`
- SMART per disk (needs root): `temp_<disk>`

### ZFS
- Pool health: `zpool_<pool>_health`
- **IOPS snapshot (inst)**:  
  `zpool_<pool>_read_iops`, `zpool_<pool>_write_iops`, `zpool_<pool>_total_iops`
- **Bandwidth snapshot (MB/s)**:  
  `zpool_<pool>_read_mbs`, `zpool_<pool>_write_mbs`, `zpool_<pool>_total_mbs`

> Derived from `zpool iostat -H -p <interval> 1` with `INSTANT_INTERVAL_SEC` (default 2s).

### Network Throughput (MB/s)
- **Average between cron runs** (per iface & totals):  
  `net_<iface>_rx_mbs`, `net_<iface>_tx_mbs`, `net_total_rx_mbs`, `net_total_tx_mbs`  
  (Uses `/sys/class/net/*/statistics/*_bytes` + state file delta.)
- **Instant snapshot (2s by default)**:  
  `net_<iface>_rx_inst_mbs`, `net_<iface>_tx_inst_mbs`, `net_total_rx_inst_mbs`, `net_total_tx_inst_mbs`

> Interfaces excluded by default: `lo`, `veth*`, `docker*`, `br*`, `virbr0`, `tailscale0`.  
> Adjust the filter list in the script if you want to include bridges/VLANs.

### CPU Wait
- Instant iowait % (snapshot): `cpu_iowait_inst_percent`

### Processes (like `top`)
- `procs_total`, `procs_running`, `procs_sleeping`, `procs_stopped`, `procs_zombie`, `procs_uninterruptible` (D)

### Updates & System
- APT updates available: `apt_updates`
- Uptime (seconds): `uptime_seconds`
- Last Run (string): `last_run` (e.g. `2025-08-22 14:03:22`)

---

## 💡 Why two network rates?

You get:
- **Average** over the whole cron interval (e.g. one minute) → smooth and good for trend/history.
- **Instant snapshot** over `INSTANT_INTERVAL_SEC` (default 2s) → more “live” feel.

---

## 🧪 `--info` mode (pretty CLI)

`--info` prints a human-readable summary grouped by category (CPU/RAM/Disks/Temps/ZFS/Network/Processes/System) **and** still publishes to MQTT.  
Use `--debug` to see each step and payload topic/value (great for troubleshooting).

---

## 🔐 Permissions

- **SMART temps** typically require root.  
- Running from root’s crontab is the simplest way to ensure access to `/sys`, `/proc`, and disks.

---

## 🛠 Troubleshooting

- **`mosquitto_pub: command not found`**  
  `sudo apt-get install -y mosquitto-clients`  
  If cron can’t find it, set `PATH=` at the top of your crontab (see Cron section).

- **No temperature sensors**  
  - On VMs: expected if you use `--vm`.  
  - On bare metal: install `lm-sensors` and run `sensors-detect` (optional), and ensure `/sys/class/hwmon` is populated. SMART temps need `smartmontools` and root.

- **No ZFS metrics**  
  Install `zfsutils-linux` and verify `zpool list` works.

- **No APT updates count**  
  Ensure `apt-get` exists (Debian/Ubuntu). On RPM distros this metric is skipped.

- **Units MB vs MiB**  
  Change `BYTES_PER_MB=1048576` to report MiB/s.

- **TLS errors**  
  Set a valid CA file via `MQTT_TLS="--cafile /path/to/ca.crt"` (or client cert options as needed).

## 🙌 Example Home Assistant Dashboard
![Example](https://github.com/davidjaedke/MQTT-Monitoring/blob/main/mqtt-monitoring-ha.jpg)

