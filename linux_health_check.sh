#!/bin/bash

# linux_health_check.sh
# version 19-05-2025 16:44 (Europe/Amsterdam)

# Kleuren
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
NC="\033[0m" # Geen kleur

function status_ok() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

function status_warn() {
    echo -e "${YELLOW}[WAARSCHUWING]${NC} $1"
}

function status_fail() {
    echo -e "${RED}[ FOUT ]${NC} $1"
}


# Systeeminformatie
echo -e "\n===== 🖥️ ${YELLOW} SYSTEEMINFORMATIE${NC} =====\n"

# Datum en tijd
datum=$(TZ=Europe/Amsterdam date +"%Y-%m-%d %H:%M:%S")
echo -e "${GREEN}Datum & tijd: ${NC}$datum (Europe/Amsterdam)"

# Hostname
hostname=$(hostname)
echo -e "${GREEN}Hostname: ${NC}$hostname"

# OS info
if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_name="$PRETTY_NAME"
else
    os_name="Onbekend besturingssysteem"
fi
echo -e "${GREEN}Besturingssysteem: ${NC}$os_name"

# CPU cores
cpu_cores=$(nproc)
echo -e "${GREEN}Aantal CPU cores: ${NC}$cpu_cores"

# Geheugen
mem_total_mb=$(free -m | awk '/Mem:/ { print $2 }')
echo -e "${GREEN}Geheugen totaal: ${NC}${mem_total_mb} MB"

# IP-adressen + subnet
ip_output=$(ip -o -f inet addr show | awk '{print $2": "$4}')
echo -e "${GREEN}IP-adressen + subnet:${NC}"
echo "$ip_output" | while read line; do
    echo "  $line"
done

# Gateway
default_gw=$(ip route | awk '/default/ {print $3}')
echo -e "${GREEN}Default gateway: ${NC}${default_gw:-Niet gevonden}"

# DNS servers
if [ -f /etc/resolv.conf ]; then
    dns_servers=$(grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}')
    if [ -n "$dns_servers" ]; then
        echo -e "${GREEN}DNS servers:${NC}"
        echo "$dns_servers" | while read dns; do
            echo "  $dns"
        done
    else
        echo -e "${YELLOW}DNS servers:${NC} geen nameservers gevonden"
    fi
else
    echo -e "${RED}DNS servers: /etc/resolv.conf niet gevonden${NC}"
fi



echo -e "\n===== 🔍 ${YELLOW}LINUX HEALTH CHECK${NC} =====\n"

# Root check
if [[ $EUID -ne 0 ]]; then
    status_fail "Dit script moet als root worden uitgevoerd."
    exit 1
fi


### 1. CPU Usage en Load average

cpu_idle1=$(grep 'cpu ' /proc/stat | awk '{print $5}')
cpu_total1=$(grep 'cpu ' /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8}')
sleep 1
cpu_idle2=$(grep 'cpu ' /proc/stat | awk '{print $5}')
cpu_total2=$(grep 'cpu ' /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8}')

idle_diff=$((cpu_idle2 - cpu_idle1))
total_diff=$((cpu_total2 - cpu_total1))

if [ "$total_diff" -ne 0 ]; then
    cpu_usage=$(( (1000 * (total_diff - idle_diff) / total_diff + 5) / 10 ))
else
    cpu_usage=0
fi

if [ "$cpu_usage" -lt 70 ]; then
    status_ok "CPU gebruik: ${cpu_usage}%"
elif [ "$cpu_usage" -lt 80 ]; then
    status_warn "CPU gebruik: ${cpu_usage}%"
else
    status_fail "CPU gebruik: ${cpu_usage}%"
fi

load_full=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)
cpu_cores=$(nproc)
load_1min=$(echo $load_full | cut -d',' -f1 | xargs)

if (( $(echo "$load_1min < $cpu_cores" | bc -l) )); then
    status_ok "Load average is $load_full (CPU cores: $cpu_cores)"
else
    status_warn "Hoge load average: $load_full (CPU cores: $cpu_cores)"
fi

### 2. Geheugengebruik
mem_used=$(free -m | awk '/Mem:/ {used=$3; free=$7; print used " " free}')
mem_used_val=$(echo $mem_used | awk '{print $1}')
mem_free_val=$(echo $mem_used | awk '{print $2}')
mem_total=$(free -m | awk '/Mem:/ {print $2}')
mem_used_pct=$(( 100 * mem_used_val / mem_total ))

if [ "$mem_used_pct" -lt 80 ]; then
    status_ok "Geheugengebruik is ${mem_used_pct}% (gebruik: ${mem_used_val}MB, vrij: ${mem_free_val}MB)"
else
    status_fail "Geheugengebruik is hoog: ${mem_used_pct}% (gebruik: ${mem_used_val}MB, vrij: ${mem_free_val}MB)"
fi

### 3. Schijfruimte (excl. snap, loop, tmpfs, udev)
df_output=$(df -h --output=source,target,avail,pcent | grep -vE "^Filesystem|loop|snap|tmpfs|udev")
echo "$df_output" | while read source mount avail usage; do
    usage_clean=$(echo "$usage" | sed 's/%//')
    if [ "$usage_clean" -lt 80 ]; then
        status_ok "Schijfgebruik op $mount is ${usage_clean}%, vrije ruimte: $avail"
    elif [ "$usage_clean" -lt 90 ]; then
        status_warn "Schijfgebruik op $mount is ${usage_clean}%, vrije ruimte: $avail"
    else
        status_fail "Schijfgebruik op $mount is ${usage_clean}%, vrije ruimte: $avail"
    fi
done

### 4. Inodes
inode_alert=$(df -i | grep -vE "snap|loop|tmpfs|udev" | awk '$5 ~ /[8-9][0-9]%/ || $5 == "100%"')
if [ -z "$inode_alert" ]; then
    status_ok "Geen inode problemen"
else
    status_fail "Inode gebruik te hoog:\n$inode_alert"
fi

### 5. Updates (verse check)
if command -v apt >/dev/null 2>&1; then
    apt update -qq >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        status_fail "Fout bij ophalen updates van apt-servers"
    else
        updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
        if [ "$updates" -eq 0 ]; then
            status_ok "Geen updates beschikbaar"
        else
            status_warn "$updates updates beschikbaar (apt)"
        fi
    fi
elif command -v yum >/dev/null 2>&1; then
    # Sla de output tijdelijk op
    check_output=$(yum check-update 2>/dev/null)
    exitcode=$?

    if [ $exitcode -eq 100 ]; then
        # Tel aantal updates (regel die niet leeg is en niet begint met pakketgroepinfo)
        updates=$(echo "$check_output" | grep -E '^[a-zA-Z0-9]' | wc -l)
        status_warn "$updates updates beschikbaar (yum)"
    elif [ $exitcode -eq 0 ]; then
        status_ok "Geen updates beschikbaar (yum)"
    else
        status_fail "Fout bij ophalen updates van yum-servers"
    fi
fi

### 6. OS versie check: huidige vs laatste bekende stabiele release + EOL check met volledige datum (CentOS, Ubuntu, Debian)

if ! command -v curl >/dev/null 2>&1; then
    status_warn "OS versiecontrole overgeslagen: 'curl' is niet geïnstalleerd"
else
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id=$ID
        os_version_major=$(echo "$VERSION_ID" | cut -d'.' -f1)

        # Functie om EOL status en datum te bepalen voor CentOS
        check_eol() {
            local version=$1
            local eol_date=""
            case "$version" in
                6)
                    eol_date="2020-11-30"
                    ;;
                7)
                    eol_date="2024-06-30"
                    ;;
                8)
                    eol_date="2021-12-31"
                    ;;
                *)
                    eol_date=""
                    ;;
            esac

            if [ -n "$eol_date" ]; then
                # Huidige datum in epoch seconden
                today_epoch=$(date +%s)
                eol_epoch=$(date -d "$eol_date" +%s)
                if [ "$today_epoch" -gt "$eol_epoch" ]; then
                    echo "EOL|$eol_date"
                else
                    echo "supported|$eol_date"
                fi
            else
                echo "unknown|"
            fi
        }

        case "$os_id" in
            ubuntu)
                # Pak laatste stabiele Ubuntu versie uit Launchpad API
                latest_version=$(curl -s https://api.launchpad.net/1.0/ubuntu/series | grep -Po '"version": "\K[0-9]{2}(?=\.[0-9]{2}")' | sort -n | tail -1)
                ;;
            debian)
                # Pak laatste stabiele Debian major versie van de website
                latest_version=$(curl -s https://www.debian.org/releases/stable/ | grep -oP 'Debian GNU/Linux \K[0-9]+' | head -1)
                ;;
            centos)
                # Bij CentOS gebruiken we predefined EOL data, dus geen externe check
                latest_version=$os_version_major
                ;;
            *)
                status_warn "OS versiecontrole niet ondersteund voor $os_id"
                latest_version=""
                ;;
        esac

        if [ -n "$latest_version" ]; then
            # Voor CentOS extra EOL check en nettere output
            if [ "$os_id" = "centos" ]; then
                read eol_status eol_date <<< $(check_eol "$os_version_major" | tr '|' ' ')

                # Format EOL datum naar "30 juni 2024"
                if [ -n "$eol_date" ]; then
                    eol_date_nl=$(LC_TIME=nl_NL.UTF-8 date -d "$eol_date" +"%e %B %Y" | sed 's/^ //')
                else
                    eol_date_nl="onbekende datum"
                fi

                if [ "$eol_status" = "EOL" ]; then
                    status_warn "OS versie $NAME $VERSION_ID is End of Life (EOL) sinds $eol_date_nl"
                else
                    status_ok "OS is ondersteund: $NAME $VERSION_ID (EOL: $eol_date_nl)"
                fi
            else
                # Ubuntu en Debian checken of versie < laatste stabiel is
                os_version_int=$(echo "$os_version_major" | sed 's/^0*//') # leidende nullen weg
                latest_version_int=$(echo "$latest_version" | sed 's/^0*//')
                if [ "$os_version_int" -lt "$latest_version_int" ]; then
                    status_warn "Verouderde OS versie: $NAME $VERSION_ID (laatste stabiel: $latest_version)"
                elif [ "$os_version_int" -eq "$latest_version_int" ]; then
                    status_ok "OS is up-to-date: $NAME $VERSION_ID"
                else
                    status_fail "Onbekende of toekomstige OS versie: $NAME $VERSION_ID (laatste stabiel: $latest_version)"
                fi
            fi
        else
            status_warn "Kon laatste versie niet bepalen voor $NAME"
        fi
    else
        status_fail "Kan OS-informatie niet bepalen (ontbreekt /etc/os-release)"
    fi
fi


### 6. Geen herstart vereist
if [ -f /var/run/reboot-required ]; then
    status_warn "Systeem vereist een herstart"
else
    status_ok "Geen herstart vereist"
fi

### 7. Uptime check
uptime_days=$(awk '{print int($1/86400)}' /proc/uptime)
if [ "$uptime_days" -lt 42 ]; then
    status_ok "Uptime is ${uptime_days} dagen"
elif [ "$uptime_days" -lt 84 ]; then
    status_warn "Uptime is ${uptime_days} dagen (langer dan 6 weken)"
else
    status_fail "Uptime is ${uptime_days} dagen (langer dan 12 weken)"
fi

### 8. Systemd services
failed_services=$(systemctl --failed --no-legend | wc -l)
if [ "$failed_services" -eq 0 ]; then
    status_ok "Geen mislukte systemd services"
else
    status_fail "$failed_services services zijn mislukt:\n$(systemctl --failed --no-pager)"
fi

### 9. Netwerk
ip_link=$(ip -o link show | grep -v LOOPBACK | grep 'state UP' | wc -l)
if [ "$ip_link" -ge 1 ]; then
    status_ok "Netwerkinterface(s) actief"
else
    status_fail "Geen actieve netwerkinterfaces"
fi

### 10. Tijd en synchronisatie
time_status=$(timedatectl show -p NTPSynchronized --value)
if [ "$time_status" = "yes" ]; then
    status_ok "Tijd is gesynchroniseerd (NTP)"
else
    status_warn "Tijd niet gesynchroniseerd met NTP"
fi

### 11. Firewall status
firewall_active=false

# UFW
if command -v ufw >/dev/null 2>&1; then
    ufw_status=$(ufw status | grep -i "Status: active")
    if [ -n "$ufw_status" ]; then
        status_ok "Firewall actief via UFW"
        firewall_active=true
    fi
fi

# firewalld
if systemctl is-active --quiet firewalld 2>/dev/null; then
    status_ok "Firewall actief via firewalld"
    firewall_active=true
fi

# nftables
if command -v nft >/dev/null 2>&1; then
    nft_rules=$(nft list ruleset 2>/dev/null | grep -v '^$')
    if [ -n "$nft_rules" ]; then
        status_ok "Firewall actief via nftables"
        firewall_active=true
    fi
fi

# iptables
if command -v iptables >/dev/null 2>&1; then
    iptables_rules=$(iptables -L | grep -vE "^Chain|target" | grep -v '^$')
    if [ -n "$iptables_rules" ]; then
        status_ok "Firewall actief via iptables"
        firewall_active=true
    fi
fi

if [ "$firewall_active" = false ]; then
    status_fail "Geen actieve firewall gedetecteerd"
fi

### 12. DNS & netwerkconfiguratie

if [ -f /etc/resolv.conf ]; then
    ns_line=$(grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)
    if [ -z "$ns_line" ]; then
        status_warn "Geen nameservers gevonden in /etc/resolv.conf"
    else
        status_ok "Nameservers in /etc/resolv.conf: $ns_line"
        # Test DNS resolutie (bijv. google.com)
        if getent hosts google.com >/dev/null 2>&1; then
            status_ok "DNS-resolutie werkt"
        else
            status_fail "DNS-resolutie faalt (kan google.com niet resolven)"
        fi
    fi
else
    status_fail "/etc/resolv.conf niet gevonden"
fi

### 13. Firewall poorten check

declare -A ports_check=(
    [21]="FTP"
    [22]="SSH"
    [23]="Telnet"
    [990]="FTPS"
)

for port in "${!ports_check[@]}"; do
    nc -z -w1 127.0.0.1 $port >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        # Port open
        if [ "$port" == "22" ]; then
            status_warn "Poort $port (${ports_check[$port]}) is open (controle of dit gewenst is!)"
        else
            status_warn "Poort $port (${ports_check[$port]}) is open"
        fi
    else
        status_ok "Poort $port (${ports_check[$port]}) is gesloten"
    fi
done

### 14. Kritieke logs
crit_logs=$(journalctl -p 3 -xb | grep -v "ACPI" | head -n 5)
if [ -z "$crit_logs" ]; then
    status_ok "Geen kritieke fouten in logs"
else
    status_warn "Kritieke logmeldingen:\n$crit_logs"
fi



echo -e "\n===== ✅ ${GREEN}Health Check Voltooid${NC} =====\n"

