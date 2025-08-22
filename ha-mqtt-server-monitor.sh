#!/usr/bin/env bash
# ha-mqtt-server-monitor.sh
# Sendet Servermetriken via MQTT an Home Assistant (inkl. MQTT Discovery).
# Features: --debug, --info, --vm, Netz-Snapshot, ZFS IO/s, Prozess-Zustände, iowait%

#####################################
#            KONFIGURATION          #
#####################################

MQTT_HOST="127.0.0.1"
MQTT_PORT="1883"
MQTT_USER=""           # optional
MQTT_PASS=""           # optional
MQTT_TLS=""            # e.g. "--cafile /etc/ssl/certs/ca-certificates.crt" (or leave empty)

DISCOVERY_PREFIX="homeassistant"
DEVICE_NAME="$(hostname)"
DEVICE_ID="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-')"
ROOT_TOPIC="servers/${DEVICE_ID}"
STATE_PREFIX="${ROOT_TOPIC}/state"

BYTES_PER_MB=1000000
STATE_FILE="/var/tmp/ha_mqtt_mon.state"

# Momentaufnahme-Intervall (Sekunden)
INSTANT_INTERVAL_SEC=2

#####################################
#           RUNTIME/FLAGS           #
#####################################

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DEBUG=0
INFO=0
IS_VM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=1 ;;
    --info)  INFO=1 ;;
    --vm)    IS_VM=1 ;;
    *) echo "Unbekannte Option: $1"; exit 64 ;;
  esac
  shift
done

log()   { echo "[$(date '+%F %T')] $*"; }
debug() { [[ $DEBUG -eq 1 ]] && log "DEBUG: $*"; }
warn()  { log "WARN: $*"; }
die()   { log "ERROR: $*"; exit "${2:-1}"; }

#####################################
#        DEPENDENCY CHECKS          #
#####################################

require_bin() {
  # require_bin <binary> <package-hint> [hard|soft]
  local bin="$1" pkg="$2" mode="${3:-hard}"
  local p; p="$(command -v "$bin" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    if [[ "$mode" == "hard" ]]; then
      die "'$bin' nicht gefunden. Bitte installieren (z.B. Debian/Ubuntu: apt-get install -y $pkg)" 127
    else
      warn "'$bin' nicht gefunden (optional). Feature wird übersprungen. (Tipp: apt-get install -y $pkg)"
      return 1
    fi
  else
    debug "Gefunden: $bin -> $p"
    echo "$p"
  fi
}

# Harte Deps
MQTT_PUB_BIN="$(require_bin mosquitto_pub mosquitto-clients hard)"
AWK_BIN="$(require_bin awk gawk hard)"
SED_BIN="$(require_bin sed sed hard)"
GREP_BIN="$(require_bin grep grep hard)"
DF_BIN="$(require_bin df coreutils hard)"
LSBLK_BIN="$(require_bin lsblk util-linux hard)"
HOSTNAME_BIN="$(require_bin hostname inetutils-hostname hard)"
DATE_BIN="$(require_bin date coreutils hard)"
SLEEP_BIN="$(require_bin sleep coreutils hard)"

# Optionale Deps
ZPOOL_BIN="$(require_bin zpool zfsutils-linux soft || true)"
SMARTCTL_BIN="$(require_bin smartctl smartmontools soft || true)"
APTGET_BIN="$(require_bin apt-get apt soft || true)"

#####################################
#         MQTT HELFER/FUNKTIONEN    #
#####################################

declare -a MQTT_ARGS
MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT")
[[ -n "$MQTT_USER" ]] && MQTT_ARGS+=(-u "$MQTT_USER")
[[ -n "$MQTT_PASS" ]] && MQTT_ARGS+=(-P "$MQTT_PASS")
if [[ -n "$MQTT_TLS" ]]; then
  # shellcheck disable=SC2206
  MQTT_ARGS+=($MQTT_TLS)
fi

mqtt_pub() {
  local topic="$1"; shift
  local payload="$1"; shift
  debug "MQTT PUB -> $topic : $payload"
  "$MQTT_PUB_BIN" "${MQTT_ARGS[@]}" -t "$topic" -m "$payload" -r "$@"
}

sanitize_id() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g; s/__\+/_/g; s/^_//; s/_$//'
}

publish_config() {
  # publish_config <sensor_id> <name> <unit> <device_class> <state_class> <icon>
  local id="$(sanitize_id "$1")"
  local name="$2" unit="$3" device_class="$4" state_class="$5" icon="$6"
  local cfg_topic="${DISCOVERY_PREFIX}/sensor/${DEVICE_ID}_${id}/config"
  local state_topic="${STATE_PREFIX}/${id}"

  local json='{'
  json+='"name":"'"$name"'"'
  json+=',"unique_id":"'"${DEVICE_ID}_${id}"'"'
  json+=',"state_topic":"'"$state_topic"'"'
  json+=',"entity_category":"diagnostic"'
  [[ -n "$unit"         ]] && json+=',"unit_of_measurement":"'"$unit"'"'
  [[ -n "$device_class" ]] && json+=',"device_class":"'"$device_class"'"'
  [[ -n "$state_class"  ]] && json+=',"state_class":"'"$state_class"'"'
  [[ -n "$icon"         ]] && json+=',"icon":"'"$icon"'"'
  json+=',"device":{"identifiers":["'"$DEVICE_ID"'"],"name":"'"$DEVICE_NAME"'","manufacturer":"ha-mqtt-bash","model":"Linux Server"}'
  json+='}'
  mqtt_pub "$cfg_topic" "$json"
}

publish_sensor() {
  # publish_sensor <sensor_id> <name> <value> <unit> <device_class> <state_class> <icon>
  local id="$1" name="$2" value="$3" unit="$4" dclass="$5" sclass="$6" icon="$7"
  publish_config "$id" "$name" "$unit" "$dclass" "$sclass" "$icon"
  mqtt_pub "${STATE_PREFIX}/$(sanitize_id "$id")" "$value"
}

#####################################
#           INFO-AUSGABE            #
#####################################

INFO_LINES=()
info_add() { INFO_LINES+=("$1|$2|$3|$4"); }
info_flush() {
  [[ $INFO -eq 1 ]] || return 0
  local host; host="$("$HOSTNAME_BIN")"
  printf "\n===== Server Monitoring Info: %s @ %s =====\n" "$host" "$("$DATE_BIN" '+%F %T')"
  local last=""
  for line in "${INFO_LINES[@]}"; do
    IFS='|' read -r cat name val unit <<<"$line"
    if [[ "$cat" != "$last" ]]; then
      printf "\n[%s]\n" "$cat"
      last="$cat"
    fi
    [[ -n "$unit" ]] && unit=" $unit"
    printf "  %-34s : %s%s\n" "$name" "$val" "$unit"
  done
  printf "\n"
}

#####################################
#           METRIC HELPERS          #
#####################################

cpu_load() { awk '{print $1}' /proc/loadavg; }
mem_used_mb() {
  awk '
    /^MemTotal:/     {t=$2}
    /^MemAvailable:/ {a=$2}
    END {
      if (t>0 && a>0) printf "%.0f", (t-a)/1024;
      else { cmd="free -m | awk \x27/Mem:/ {print $3}\x27"; cmd|getline u; close(cmd); print u }
    }' /proc/meminfo
}
mem_total_mb() { awk '/^MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo; }
percent() { awk -v v="$1" -v t="$2" 'BEGIN{ if(t>0) printf "%.1f", (v*100.0)/t; else print "0.0"}'; }

zpool_health_list() {
  [[ -n "$ZPOOL_BIN" ]] || return 1
  "$ZPOOL_BIN" list -H -o name,health 2>/dev/null
}
zpool_names() {
  if [[ -n "$ZPOOL_BIN" ]]; then
    "$ZPOOL_BIN" list -H -o name 2>/dev/null
  fi
}

disk_usage_list() {
  "$DF_BIN" -P -B1 \
    -x tmpfs -x devtmpfs -x squashfs -x overlay -x zram -x udf -x iso9660 -x ramfs \
    | awk 'NR>1 {print $1, $6, $2, $3, $5}'
}

publish_hwmon_temps() {
  [[ $IS_VM -eq 1 ]] && { debug "VM-Modus aktiv – hwmon-Temps übersprungen"; return; }
  local any=0
  for hw in /sys/class/hwmon/hwmon*; do
    [[ -d "$hw" ]] || continue
    local chip; chip="$(cat "$hw/name" 2>/dev/null || echo "hwmon")"
    for tin in "$hw"/temp*_input; do
      [[ -e "$tin" ]] || continue
      local labelfile="${tin%_input}_label"
      local label; label="$(cat "$labelfile" 2>/dev/null || basename "${tin%_input}")"
      local milli; milli="$(cat "$tin" 2>/dev/null || echo "")"
      [[ -n "$milli" ]] || continue
      local c; c=$(awk -v m="$milli" 'BEGIN{ printf "%.1f", m/1000.0 }')
      local sid="temp_${chip}_${label}"
      sid="$(echo "$sid" | tr ' /-' '___')"
      publish_sensor "$sid" "Temp ${chip} ${label}" "$c" "°C" "temperature" "measurement" "mdi:thermometer"
      info_add "Temperaturen" "Temp ${chip} ${label}" "$c" "°C"
      any=1
    done
  done
  [[ $any -eq 0 ]] && debug "Keine hwmon-Temperatursensoren gefunden"
}

publish_smart_temps() {
  [[ $IS_VM -eq 1 ]] && { debug "VM-Modus aktiv – SMART-Temps übersprungen"; return; }
  [[ -n "$SMARTCTL_BIN" ]] || { debug "smartctl fehlt – SMART-Temps übersprungen"; return; }
  if [[ $EUID -ne 0 ]]; then
    warn "SMART benötigt Root. Bitte Cron als root ausführen."
    return
  fi
  mapfile -t disks < <("$LSBLK_BIN" -ndo NAME,TYPE | awk '$2=="disk"{print $1}')
  for d in "${disks[@]}"; do
    local dev="/dev/$d" out temp=""
    out="$("$SMARTCTL_BIN" -A "$dev" 2>/dev/null)" || continue
    temp="$(awk -F':' '/Temperature:/{gsub(/[^0-9.]/,"",$2); if($2!=""){print $2}}' <<<"$out")"
    if [[ -z "$temp" ]]; then
      temp="$(awk '/^194[ ]|Temperature_Celsius|Current Drive Temperature|Airflow_Temperature_Cel/{
        for(i=NF;i>=1;i--){ if ($i ~ /^[0-9]+$/){ print $i; exit } }
      }' <<<"$out")"
    fi
    [[ -n "$temp" ]] || continue
    publish_sensor "temp_${d}" "Temp ${d}" "$(printf "%.1f" "$temp")" "°C" "temperature" "measurement" "mdi:harddisk"
    info_add "Temperaturen" "Temp ${d}" "$(printf "%.1f" "$temp")" "°C"
  done
}

apt_updates_count() {
  [[ -n "$APTGET_BIN" ]] || { echo "0"; return; }
  LC_ALL=C DEBIAN_FRONTEND=noninteractive "$APTGET_BIN" -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null \
    | awk 'BEGIN{n=0} /^Inst /{n++} END{print n}'
}

#####################################
#      NET & CPU SNAPSHOT/AVG       #
#####################################

# Durchschnitt über Cron-Intervall
publish_net_rates() {
  local now; now="$(date +%s)"
  local last_time=0
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

  local dt=$(( now - last_time ))
  (( dt <= 0 )) && dt=1

  local total_rx_delta=0 total_tx_delta=0
  for ifc in /sys/class/net/*; do
    [[ -d "$ifc" ]] || continue
    local iface; iface="$(basename "$ifc")"
    [[ "$iface" == "lo" || "$iface" == veth* || "$iface" == docker* || "$iface" == br* || "$iface" == "virbr0" || "$iface" == "tailscale0" ]] && continue

    local rx_file="$ifc/statistics/rx_bytes"
    local tx_file="$ifc/statistics/tx_bytes"
    [[ -r "$rx_file" && -r "$tx_file" ]] || continue

    local rx; rx="$(cat "$rx_file")"
    local tx; tx="$(cat "$tx_file")"

    local prev_rx_var="rx_bytes_${iface}"
    local prev_tx_var="tx_bytes_${iface}"
    local prev_rx="${!prev_rx_var:-0}"
    local prev_tx="${!prev_tx_var:-0}"

    local drx=$(( rx - prev_rx ))
    local dtx=$(( tx - prev_tx ))
    (( drx < 0 )) && drx=0
    (( dtx < 0 )) && dtx=0

    total_rx_delta=$(( total_rx_delta + drx ))
    total_tx_delta=$(( total_tx_delta + dtx ))

    local rx_mbs tx_mbs
    rx_mbs=$(awk -v b="$drx" -v dt="$dt" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
    tx_mbs=$(awk -v b="$dtx" -v dt="$dt" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')

    publish_sensor "net_${iface}_rx_mbs" "Net ${iface} RX" "$rx_mbs" "MB/s" "" "measurement" "mdi:download-network"
    publish_sensor "net_${iface}_tx_mbs" "Net ${iface} TX" "$tx_mbs" "MB/s" "" "measurement" "mdi:upload-network"
    info_add "Netzwerk (Durchschnitt)" "Net ${iface} RX" "$rx_mbs" "MB/s"
    info_add "Netzwerk (Durchschnitt)" "Net ${iface} TX" "$tx_mbs" "MB/s"

    eval "${prev_rx_var}=$rx"
    eval "${prev_tx_var}=$tx"
  done

  local total_rx_mbs total_tx_mbs
  total_rx_mbs=$(awk -v b="$total_rx_delta" -v dt="$dt" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
  total_tx_mbs=$(awk -v b="$total_tx_delta" -v dt="$dt" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
  publish_sensor "net_total_rx_mbs" "Net Total RX" "$total_rx_mbs" "MB/s" "" "measurement" "mdi:download-network"
  publish_sensor "net_total_tx_mbs" "Net Total TX" "$total_tx_mbs" "MB/s" "" "measurement" "mdi:upload-network"
  info_add "Netzwerk (Durchschnitt)" "Total RX" "$total_rx_mbs" "MB/s"
  info_add "Netzwerk (Durchschnitt)" "Total TX" "$total_tx_mbs" "MB/s"

  {
    echo "last_time=$now"
    for var in $(compgen -A variable | grep -E '^rx_bytes_|^tx_bytes_'); do
      echo "$var=${!var}"
    done
  } >"$STATE_FILE"
}

# Momentaufnahme: Netz + CPU iowait%
publish_net_rates_snapshot() {
  local interval="${INSTANT_INTERVAL_SEC:-2}"
  (( interval < 1 )) && interval=1

  mapfile -t ifaces < <(
    for ifc in /sys/class/net/*; do
      [[ -d "$ifc" ]] || continue
      local iface; iface="$(basename "$ifc")"
      [[ "$iface" == "lo" || "$iface" == veth* || "$iface" == docker* || "$iface" == br* || "$iface" == "virbr0" || "$iface" == "tailscale0" ]] && continue
      echo "$iface"
    done
  )

  # CPU jiffies vor dem Snapshot
  read -r t0 iw0 < <(awk '/^cpu /{t=0; for(i=2;i<=11;i++) t+=$i; print t,$6; exit}' /proc/stat)

  # Erste Netzmessung
  declare -a rx0 tx0
  for i in "${!ifaces[@]}"; do
    local f="/sys/class/net/${ifaces[$i]}/statistics"
    rx0[$i]=$(cat "$f/rx_bytes" 2>/dev/null || echo 0)
    tx0[$i]=$(cat "$f/tx_bytes" 2>/dev/null || echo 0)
  done

  "$SLEEP_BIN" "$interval"

  # CPU jiffies nach dem Snapshot
  read -r t1 iw1 < <(awk '/^cpu /{t=0; for(i=2;i<=11;i++) t+=$i; print t,$6; exit}' /proc/stat)
  local dtj=$(( t1 - t0 )); (( dtj<=0 )) && dtj=1
  local diw=$(( iw1 - iw0 )); (( diw<0 )) && diw=0
  local iowait_inst
  iowait_inst=$(awk -v i="$diw" -v t="$dtj" 'BEGIN{printf "%.1f", (i*100.0)/t}')
  publish_sensor "cpu_iowait_inst_percent" "CPU iowait (inst) %" "$iowait_inst" "%" "" "measurement" "mdi:timer-sand"
  info_add "CPU (Snapshot)" "iowait" "$iowait_inst" "%"

  local total_rx_delta=0 total_tx_delta=0
  for i in "${!ifaces[@]}"; do
    local iface="${ifaces[$i]}"
    local f="/sys/class/net/${iface}/statistics"
    local rx1 tx1 drx dtx
    rx1=$(cat "$f/rx_bytes" 2>/dev/null || echo 0)
    tx1=$(cat "$f/tx_bytes" 2>/dev/null || echo 0)
    drx=$(( rx1 - rx0[$i] )); (( drx < 0 )) && drx=0
    dtx=$(( tx1 - tx0[$i] )); (( dtx < 0 )) && dtx=0

    total_rx_delta=$(( total_rx_delta + drx ))
    total_tx_delta=$(( total_tx_delta + dtx ))

    local rx_mbs tx_mbs
    rx_mbs=$(awk -v b="$drx" -v dt="$interval" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
    tx_mbs=$(awk -v b="$dtx" -v dt="$interval" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')

    publish_sensor "net_${iface}_rx_inst_mbs" "Net ${iface} RX (inst)" "$rx_mbs" "MB/s" "" "measurement" "mdi:download-network"
    publish_sensor "net_${iface}_tx_inst_mbs" "Net ${iface} TX (inst)" "$tx_mbs" "MB/s" "" "measurement" "mdi:upload-network"
    info_add "Netzwerk (Snapshot)" "Net ${iface} RX (inst)" "$rx_mbs" "MB/s"
    info_add "Netzwerk (Snapshot)" "Net ${iface} TX (inst)" "$tx_mbs" "MB/s"
  done

  local total_rx_mbs total_tx_mbs
  total_rx_mbs=$(awk -v b="$total_rx_delta" -v dt="$interval" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
  total_tx_mbs=$(awk -v b="$total_tx_delta" -v dt="$interval" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", (b/dt)/MB}')
  publish_sensor "net_total_rx_inst_mbs" "Net Total RX (inst)" "$total_rx_mbs" "MB/s" "" "measurement" "mdi:download-network"
  publish_sensor "net_total_tx_inst_mbs" "Net Total TX (inst)" "$total_tx_mbs" "MB/s" "" "measurement" "mdi:upload-network"
  info_add "Netzwerk (Snapshot)" "Total RX (inst)" "$total_rx_mbs" "MB/s"
  info_add "Netzwerk (Snapshot)" "Total TX (inst)" "$total_tx_mbs" "MB/s"
}

#####################################
#         ZFS IOPS SNAPSHOT         #
#####################################

publish_zpool_iops_snapshot() {
  [[ -n "$ZPOOL_BIN" ]] || { debug "zpool fehlt – ZFS IO/s übersprungen"; return; }
  mapfile -t pools < <("$ZPOOL_BIN" list -H -o name 2>/dev/null)
  (( ${#pools[@]} )) || { debug "Keine ZFS-Pools gefunden"; return; }

  local interval="${INSTANT_INTERVAL_SEC:-2}"
  (( interval < 1 )) && interval=1

  # -H: headerless, -p: genaue Zahlen, <interval> 1: Snapshot über N Sekunden
  local out; out="$("$ZPOOL_BIN" iostat -H -p "$interval" 1 2>/dev/null)" || return
  while read -r line; do
    [[ -z "$line" ]] && continue
    # Format: name alloc free rops wops rbytes wbytes
    set -- $line
    local name="$1" rops="$4" wops="$5" rbytes="$6" wbytes="$7"

    # Nur echte Pools nehmen
    if printf '%s\0' "${pools[@]}" | grep -Fzxq "$name"; then
      local rmbs wmbs
      rmbs=$(awk -v b="$rbytes" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", b/MB}')
      wmbs=$(awk -v b="$wbytes" -v MB="$BYTES_PER_MB" 'BEGIN{printf "%.1f", b/MB}')

      # Getrennte Sensoren (bestehende IDs beibehalten)
      publish_sensor "zpool_${name}_read_iops"   "ZFS ${name} read IOPS (inst)"   "$rops" "ops/s" "" "measurement" "mdi:pool"
      publish_sensor "zpool_${name}_write_iops"  "ZFS ${name} write IOPS (inst)"  "$wops" "ops/s" "" "measurement" "mdi:pool"
      publish_sensor "zpool_${name}_read_mbs"    "ZFS ${name} read (inst)"        "$rmbs" "MB/s"  "" "measurement" "mdi:pool"
      publish_sensor "zpool_${name}_write_mbs"   "ZFS ${name} write (inst)"       "$wmbs" "MB/s"  "" "measurement" "mdi:pool"

      # Zusätzliche Totals (optional hilfreich)
      local iops_total mbs_total
      iops_total=$(awk -v r="$rops" -v w="$wops" 'BEGIN{printf "%.0f", r+w}')
      mbs_total=$(awk -v r="$rmbs" -v w="$wmbs" 'BEGIN{printf "%.1f", r+w}')
      publish_sensor "zpool_${name}_total_iops"  "ZFS ${name} total IOPS (inst)"  "$iops_total" "ops/s" "" "measurement" "mdi:pool"
      publish_sensor "zpool_${name}_total_mbs"   "ZFS ${name} total (inst)"       "$mbs_total"  "MB/s"  "" "measurement" "mdi:pool"

      # INFO-Ausgabe: sauber getrennt
      info_add "ZFS IO (Snapshot)" "Pool ${name} read IOPS"   "$rops"   "ops/s"
      info_add "ZFS IO (Snapshot)" "Pool ${name} read MB/s"   "$rmbs"   "MB/s"
      info_add "ZFS IO (Snapshot)" "Pool ${name} write IOPS"  "$wops"   "ops/s"
      info_add "ZFS IO (Snapshot)" "Pool ${name} write MB/s"  "$wmbs"   "MB/s"
      info_add "ZFS IO (Snapshot)" "Pool ${name} total IOPS"  "$iops_total" "ops/s"
      info_add "ZFS IO (Snapshot)" "Pool ${name} total MB/s"  "$mbs_total"  "MB/s"
    fi
  done <<< "$(awk 'NF>0{print}' <<<"$out")"
}


#####################################
#       PROZESS-ZUSTÄNDE (top)      #
#####################################

publish_process_states() {
  local total=0 r=0 s=0 t=0 z=0 d=0
  shopt -s nullglob
  for statusf in /proc/[0-9]*/status; do
    total=$((total+1))
    # State: R=running, S=sleeping, D=uninterruptible sleep, T=stopped, Z=zombie, I=idle (kernel)
    local st
    st="$(awk -F'[: \t]+' '/^State:/ {print $2; exit}' "$statusf" 2>/dev/null)"
    case "$st" in
      R) r=$((r+1));;
      S) s=$((s+1));;
      D) d=$((d+1)); s=$((s+1));;   # D zählt in top auch zu sleeping
      T|t) t=$((t+1));;
      Z) z=$((z+1));;
      I) s=$((s+1));;               # kernel idle -> sleeping
    esac
  done

  # MQTT-Sensoren (wie gehabt)
  publish_sensor "procs_total"           "Procs total"                  "$total" "" "" "measurement" "mdi:source-branch"
  publish_sensor "procs_running"         "Procs running"                "$r"     "" "" "measurement" "mdi:run-fast"
  publish_sensor "procs_sleeping"        "Procs sleeping"               "$s"     "" "" "measurement" "mdi:sleep"
  publish_sensor "procs_stopped"         "Procs stopped"                "$t"     "" "" "measurement" "mdi:pause-octagon"
  publish_sensor "procs_zombie"          "Procs zombie"                 "$z"     "" "" "measurement" "mdi:skull"
  publish_sensor "procs_uninterruptible" "Procs uninterruptible (D)"    "$d"     "" "" "measurement" "mdi:progress-wrench"

  # INFO-Ausgabe: jetzt EINZELN, nicht mehr als Summary-Zeile
  info_add "Prozesse" "Total"                    "$total"
  info_add "Prozesse" "Running"                  "$r"
  info_add "Prozesse" "Sleeping"                 "$s"
  info_add "Prozesse" "Stopped"                  "$t"
  info_add "Prozesse" "Zombie"                   "$z"
  info_add "Prozesse" "Uninterruptible (D)"      "$d"
}


#####################################
#              MAIN                 #
#####################################

main() {
  debug "Start - Host=$DEVICE_NAME ($DEVICE_ID), VM=$IS_VM, INFO=$INFO, Snapshot=${INSTANT_INTERVAL_SEC}s"

  # CPU Load
  local load1; load1="$(cpu_load)"
  publish_sensor "cpu_load_1m" "CPU Load 1m" "$load1" "" "" "measurement" "mdi:cpu-64-bit"
  info_add "CPU" "Load (1m)" "$load1"

  # RAM
  local mem_used mem_total mem_pct
  mem_used="$(mem_used_mb)"
  mem_total="$(mem_total_mb)"
  mem_pct="$(percent "$mem_used" "$mem_total")"
  publish_sensor "ram_used_mb" "RAM Used" "$mem_used" "MB" "" "measurement" "mdi:memory"
  publish_sensor "ram_total_mb" "RAM Total" "$mem_total" "MB" "" "measurement" "mdi:memory"
  publish_sensor "ram_used_percent" "RAM Used %" "$mem_pct" "%" "" "measurement" "mdi:memory"
  info_add "RAM" "Used" "$mem_used" "MB"
  info_add "RAM" "Total" "$mem_total" "MB"
  info_add "RAM" "Used %" "$mem_pct" "%"

  # ZFS Health
  if zlist="$(zpool_health_list)"; then
    if [[ -n "$zlist" ]]; then
      while read -r pool health; do
        [[ -z "$pool" || -z "$health" ]] && continue
        publish_sensor "zpool_${pool}_health" "ZFS ${pool} Health" "$health" "" "" "" "mdi:pool"
        info_add "ZFS" "Pool ${pool} Health" "$health"
      done <<<"$zlist"
    else
      info_add "ZFS" "Pools" "keine" ""
      publish_sensor "zpool_status" "ZFS Status" "no_pools" "" "" "" "mdi:pool"
    fi
  else
    info_add "ZFS" "zpool" "nicht installiert" ""
  fi

  # Disk Usage pro Mount
  while read -r fs mount total used usedpct; do
    [[ -z "$mount" ]] && continue
    local pct_clean; pct_clean="$(echo "$usedpct" | tr -d '%')"
    publish_sensor "$(sanitize_id "disk_${mount}_used_percent")" "Disk ${mount} Used %" "$pct_clean" "%" "" "measurement" "mdi:harddisk"
    publish_sensor "$(sanitize_id "disk_${mount}_used_mb")" "Disk ${mount} Used" "$(awk -v b="$used" 'BEGIN{printf "%.0f", b/1048576}')" "MB" "" "measurement" "mdi:harddisk"
    publish_sensor "$(sanitize_id "disk_${mount}_total_mb")" "Disk ${mount} Total" "$(awk -v b="$total" 'BEGIN{printf "%.0f", b/1048576}')" "MB" "" "measurement" "mdi:harddisk"
    info_add "Disks" "Mount ${mount} Used %" "$pct_clean" "%"
  done < <(disk_usage_list)

  # Temperaturen
  publish_hwmon_temps
  publish_smart_temps

  # APT Updates
  if [[ -n "$APTGET_BIN" ]]; then
    local upcnt; upcnt="$(apt_updates_count)"
    publish_sensor "apt_updates" "APT Updates available" "$upcnt" "" "" "measurement" "mdi:package-up"
    info_add "Updates" "APT Updates verfügbar" "$upcnt"
  else
    info_add "Updates" "APT" "nicht installiert"
  fi

  # Prozesse (top-ähnlich)
  publish_process_states

  # Netzwerk (Durchschnitt über Cron-Intervall)
  publish_net_rates

  # Netzwerk & CPU iowait (Momentaufnahme über kurzes Intervall)
  publish_net_rates_snapshot

  # ZFS IO/s + MB/s (Momentaufnahme)
  publish_zpool_iops_snapshot

  # Uptime & Letzter Lauf (als String)
  local up_s; up_s="$(awk '{print int($1)}' /proc/uptime)"
  publish_sensor "uptime_seconds" "Uptime" "$up_s" "s" "" "measurement" "mdi:clock-outline"
  publish_sensor "last_run" "Last Run" "$("$DATE_BIN" '+%F %T')" "" "" "" "mdi:update"
  info_add "System" "Uptime" "$up_s" "s"
  info_add "System" "Last Run" "$("$DATE_BIN" '+%F %T')"

  info_flush
  debug "Fertig."
}

main

