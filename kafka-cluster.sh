#!/usr/bin/env bash
# Kafka Cluster Bootstrapper (Ubuntu) - KRaft mode (no ZooKeeper)
# هدف: راه‌اندازی کلاستر کافکا با حداقل ورودی، همراه با منوی مدیریت/عیب‌یابی
#
# نکته مهم: «کاملاً بدون باگ» در دنیای واقعی تضمین‌پذیر نیست، اما این اسکریپت
# با چک‌های پیشگیرانه، خطایابی بهتر و مسیرهای امن، ریسک خطا را کم می‌کند.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/kafka-bootstrap.log"

KAFKA_VERSION_DEFAULT="3.7.1"
SCALA_VERSION_DEFAULT="2.13"
KAFKA_VERSIONS_CACHE="/tmp/kafka-versions-cache.txt"
KAFKA_VERSIONS_CACHE_AGE=3600  # 1 hour
KAFKA_BASE_DIR="/opt/kafka"
KAFKA_SYMLINK="/opt/kafka/current"
KAFKA_USER="kafka"
KAFKA_GROUP="kafka"
KAFKA_ETC_DIR="/etc/kafka"
KAFKA_DATA_DIR_DEFAULT="/var/lib/kafka"
KAFKA_LOG_DIR_DEFAULT="/var/log/kafka"
KAFKA_ENV_FILE="/etc/default/kafka"
SYSTEMD_UNIT="/etc/systemd/system/kafka.service"

# KRaft ports (defaults)
CONTROLLER_PORT_DEFAULT="9093"
BROKER_PORT_DEFAULT="9092"

RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YLW="$(printf '\033[33m')"
BLU="$(printf '\033[34m')"
RST="$(printf '\033[0m')"

die() {
  echo "${RED}خطا:${RST} $*" >&2
  exit 1
}

warn() { echo "${YLW}هشدار:${RST} $*" >&2; }
info() { echo "${BLU}اطلاع:${RST} $*"; }
ok()   { echo "${GRN}موفق:${RST} $*"; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "این اسکریپت باید با دسترسی روت اجرا شود. مثال: sudo ./${SCRIPT_NAME}"
  fi
}

log_init() {
  mkdir -p "$(dirname "$LOG_FILE")" || true
  touch "$LOG_FILE" 2>/dev/null || true
  # اجازه خواندن لاگ برای کاربر روت
  chmod 0644 "$LOG_FILE" 2>/dev/null || true
}

on_error() {
  local exit_code=$?
  local line_no=${1:-"?"}
  echo
  warn "═══════════════════════════════════════════════════"
  warn "خطا: اجرا در خط ${line_no} با کد ${exit_code} متوقف شد."
  warn "═══════════════════════════════════════════════════"
  if [[ -r "$LOG_FILE" ]]; then
    echo
    echo "آخرین 30 خط لاگ:"
    echo "───────────────────────────────────────────────────────"
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
    echo "───────────────────────────────────────────────────────"
    echo
    echo "برای مشاهده کل لاگ: sudo cat $LOG_FILE | less"
  else
    warn "فایل لاگ قابل خواندن نیست: $LOG_FILE"
    warn "لطفاً دسترسی فایل را چک کنید: ls -la $LOG_FILE"
  fi
  echo
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

run() {
  # اجرا + لاگ
  # shellcheck disable=SC2124
  local cmd="$*"
  echo "[$(date -Is)] $cmd" >>"$LOG_FILE"
  eval "$cmd" >>"$LOG_FILE" 2>&1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

assert_ubuntu() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
      warn "این اسکریپت برای اوبونتو/دبیان طراحی شده. سیستم شما: ID=${ID:-unknown}"
    fi
  else
    warn "فایل /etc/os-release پیدا نشد؛ تشخیص توزیع ممکن نیست."
  fi
}

require_tools() {
  local missing=()
  for t in curl tar sha512sum awk sed grep ss systemctl id getent; do
    have_cmd "$t" || missing+=("$t")
  done
  if ((${#missing[@]} > 0)); then
    die "ابزارهای زیر موجود نیستند: ${missing[*]} (احتمالاً سیستم مینیمال است). ابتدا نصب کنید."
  fi
}

check_disk_space() {
  local path="$1"
  local min_gb="$2"
  info "چک فضای دیسک برای ${path} (حداقل ${min_gb} GB) ..."
  
  local avail_kb
  avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "$avail_kb" ]]; then
    warn "نتوانستم فضای دیسک ${path} را چک کنم."
    return 0
  fi
  
  local avail_gb=$((avail_kb / 1024 / 1024))
  if ((avail_gb < min_gb)); then
    die "فضای دیسک کافی نیست! موجود: ${avail_gb}GB، لازم: ${min_gb}GB. لطفاً فضا آزاد کنید."
  fi
  ok "فضای دیسک کافی است: ${avail_gb}GB موجود"
}

check_memory() {
  local min_mb="$1"
  info "چک حافظه RAM (حداقل ${min_mb} MB) ..."
  
  if [[ ! -f /proc/meminfo ]]; then
    warn "نتوانستم اطلاعات RAM را بخوانم."
    return 0
  fi
  
  local total_kb
  total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  local total_mb=$((total_kb / 1024))
  
  if ((total_mb < min_mb)); then
    die "حافظه RAM کافی نیست! موجود: ${total_mb}MB، لازم: ${min_mb}MB"
  fi
  ok "حافظه RAM کافی است: ${total_mb}MB موجود"
}

check_internet_access() {
  info "تست دسترسی اینترنت ..."
  
  local test_urls=(
    "https://downloads.apache.org"
    "https://www.google.com"
    "https://1.1.1.1"
  )
  
  local success=0
  for url in "${test_urls[@]}"; do
    if curl -fsSL --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1; then
      success=1
      break
    fi
  done
  
  if ((success == 0)); then
    die "دسترسی اینترنت وجود ندارد! لطفاً اتصال شبکه را چک کنید."
  fi
  ok "دسترسی اینترنت موجود است"
}

fix_dns_if_needed() {
  info "چک تنظیمات DNS ..."
  
  if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then
    warn "هیچ nameserver در /etc/resolv.conf یافت نشد. اضافه کردن DNS عمومی..."
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    ok "DNS عمومی اضافه شد"
  else
    ok "تنظیمات DNS موجود است"
  fi
}

apt_install_prereqs() {
  info "نصب پیش‌نیازها (Java, curl, ابزارهای شبکه) ..."
  
  # چک فضای دیسک قبل از نصب
  check_disk_space "/var" 5
  check_disk_space "/opt" 2
  check_memory 1024
  
  # رفع مشکلات احتمالی apt
  if [[ -f /var/lib/dpkg/lock ]] || [[ -f /var/lib/apt/lists/lock ]]; then
    warn "فایل‌های قفل apt پیدا شد. حذف می‌شوند..."
    rm -f /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
    run "dpkg --configure -a"
  fi
  
  fix_dns_if_needed
  check_internet_access
  
  # تلاش برای update با retry
  local retry=0
  local max_retries=3
  while ((retry < max_retries)); do
    if DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$LOG_FILE" 2>&1; then
      break
    fi
    retry=$((retry + 1))
    warn "apt-get update ناموفق بود (تلاش ${retry}/${max_retries}). صبر کنید..."
    sleep 5
  done
  
  if ((retry == max_retries)); then
    die "apt-get update پس از ${max_retries} تلاش ناموفق ماند."
  fi
  
  run "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless curl ca-certificates tar coreutils gawk sed grep iproute2 lsof util-linux net-tools jq ufw systemd"
  ok "پیش‌نیازها نصب شدند."
}

ensure_user() {
  if id "$KAFKA_USER" >/dev/null 2>&1; then
    ok "کاربر سرویس ${KAFKA_USER} از قبل وجود دارد."
  else
    info "ایجاد کاربر سرویس ${KAFKA_USER} ..."
    run "useradd --system --home ${KAFKA_BASE_DIR} --shell /usr/sbin/nologin --user-group ${KAFKA_USER}"
    ok "کاربر سرویس ایجاد شد."
  fi
}

ensure_dirs() {
  local data_dir="${1:-$KAFKA_DATA_DIR_DEFAULT}"
  local log_dir="${2:-$KAFKA_LOG_DIR_DEFAULT}"

  run "mkdir -p ${KAFKA_BASE_DIR} ${KAFKA_ETC_DIR} ${data_dir} ${log_dir}"
  run "chown -R ${KAFKA_USER}:${KAFKA_GROUP} ${data_dir} ${log_dir} ${KAFKA_BASE_DIR}"
  run "chmod 0750 ${data_dir} ${log_dir} ${KAFKA_ETC_DIR}"
}

port_free_or_die() {
  local port="$1"
  if ss -lnt "( sport = :$port )" | awk 'NR>1{exit 0} END{exit 1}'; then
    die "پورت $port در حال استفاده است. سرویس/پروسه‌ای روی این پورت گوش می‌دهد."
  fi
}

validate_hostname_or_ip() {
  local host="$1"
  if [[ -z "$host" ]]; then
    die "مقدار خالی برای میزبان/آی‌پی معتبر نیست."
  fi
  if ! getent hosts "$host" >/dev/null 2>&1; then
    warn "نام/آدرس '$host' با DNS/hosts resolve نشد. اگر آی‌پی خصوصی است یا DNS ندارید، اشکالی ندارد ولی توصیه می‌شود درستش کنید."
  fi
}

prompt_default() {
  local prompt="$1"
  local def="$2"
  local var
  read -r -p "$prompt [$def]: " var
  if [[ -z "${var}" ]]; then
    echo "$def"
  else
    echo "$var"
  fi
}

prompt_secret() {
  local prompt="$1"
  local var
  read -r -s -p "$prompt: " var
  echo
  echo "$var"
}

fetch_kafka_versions() {
  # این تابع فقط نسخه‌ها را به stdout می‌فرستد (بدون پیام‌های اضافی)
  
  local cache_valid=0
  if [[ -f "$KAFKA_VERSIONS_CACHE" ]]; then
    local cache_age
    cache_age=$(($(date +%s) - $(stat -c %Y "$KAFKA_VERSIONS_CACHE" 2>/dev/null || echo "0")))
    if ((cache_age < KAFKA_VERSIONS_CACHE_AGE)); then
      cache_valid=1
    fi
  fi
  
  if ((cache_valid == 1)); then
    cat "$KAFKA_VERSIONS_CACHE" 2>/dev/null
    return 0
  fi
  
  # تلاش برای دریافت از Apache Maven Repository
  local versions_url="https://repo1.maven.org/maven2/org/apache/kafka/kafka-server-common/maven-metadata.xml"
  
  if curl -fsSL --connect-timeout 10 --max-time 30 "$versions_url" 2>/dev/null | \
     grep -oP '<version>\K[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | \
     sort -V -r > "$KAFKA_VERSIONS_CACHE.tmp" 2>/dev/null; then
    
    if [[ -s "$KAFKA_VERSIONS_CACHE.tmp" ]]; then
      mv "$KAFKA_VERSIONS_CACHE.tmp" "$KAFKA_VERSIONS_CACHE"
      cat "$KAFKA_VERSIONS_CACHE" 2>/dev/null
      return 0
    fi
  fi
  
  # روش جایگزین: دریافت از Apache Archive
  local archive_url="https://archive.apache.org/dist/kafka/"
  
  if curl -fsSL --connect-timeout 10 --max-time 30 "$archive_url" 2>/dev/null | \
     grep -oP 'href="\K[0-9]+\.[0-9]+\.[0-9]+(?=/")' 2>/dev/null | \
     sort -V -r | head -20 > "$KAFKA_VERSIONS_CACHE.tmp" 2>/dev/null; then
    
    if [[ -s "$KAFKA_VERSIONS_CACHE.tmp" ]]; then
      mv "$KAFKA_VERSIONS_CACHE.tmp" "$KAFKA_VERSIONS_CACHE"
      cat "$KAFKA_VERSIONS_CACHE" 2>/dev/null
      return 0
    fi
  fi
  
  # Fallback: لیست دستی نسخه‌های معروف اخیر (به‌روزرسانی شده)
  cat > "$KAFKA_VERSIONS_CACHE" <<'EOF'
3.8.0
3.7.1
3.7.0
3.6.2
3.6.1
3.6.0
3.5.2
3.5.1
3.5.0
3.4.1
3.4.0
3.3.2
3.3.1
3.3.0
3.2.3
3.2.2
3.2.1
3.2.0
EOF
  cat "$KAFKA_VERSIONS_CACHE" 2>/dev/null
  return 0
}

select_kafka_version() {
  local selected_version=""
  
  echo
  info "دریافت نسخه‌های موجود..."
  
  # دریافت نسخه‌ها به صورت آرایه
  local versions_str
  versions_str=$(fetch_kafka_versions)
  
  if [[ -z "$versions_str" ]]; then
    warn "نتوانستم نسخه‌ها را دریافت کنم. از نسخه پیش‌فرض استفاده می‌شود."
    echo "$KAFKA_VERSION_DEFAULT"
    return 0
  fi
  
  # تبدیل string به array
  local versions=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && versions+=("$line")
  done <<< "$versions_str"
  
  if ((${#versions[@]} == 0)); then
    warn "هیچ نسخه‌ای یافت نشد. از نسخه پیش‌فرض استفاده می‌شود."
    echo "$KAFKA_VERSION_DEFAULT"
    return 0
  fi
  
  echo
  echo "═══════════════════════════════════════════════════"
  echo "نسخه‌های موجود Kafka (جدیدترین اول):"
  echo "═══════════════════════════════════════════════════"
  local i=1
  for version in "${versions[@]}"; do
    if [[ "$version" == "$KAFKA_VERSION_DEFAULT" ]]; then
      echo "  [$i] $version ${GRN}← پیش‌فرض (توصیه می‌شود)${RST}"
    else
      echo "  [$i] $version"
    fi
    i=$((i + 1))
    # فقط 20 نسخه اول را نمایش بده
    if ((i > 20)); then
      echo "  ... (${#versions[@]} نسخه موجود)"
      break
    fi
  done
  echo "  [0] وارد کردن دستی نسخه"
  echo "═══════════════════════════════════════════════════"
  echo
  
  while true; do
    read -r -p "انتخاب نسخه (0-${#versions[@]} یا Enter برای پیش‌فرض): " choice
    choice="${choice:-default}"
    
    if [[ "$choice" == "default" ]] || [[ "$choice" == "" ]]; then
      selected_version="$KAFKA_VERSION_DEFAULT"
      ok "نسخه پیش‌فرض انتخاب شد: $selected_version"
      break
    elif [[ "$choice" == "0" ]]; then
      read -r -p "نسخه را وارد کنید (مثال: 3.7.1): " manual_version
      if [[ "$manual_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        selected_version="$manual_version"
        ok "نسخه دستی انتخاب شد: $selected_version"
        break
      else
        warn "فرمت نسخه نامعتبر است. باید به فرمت X.Y.Z باشد (مثال: 3.7.1)."
      fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#versions[@]})); then
      selected_version="${versions[$((choice - 1))]}"
      ok "نسخه انتخاب شد: $selected_version"
      break
    else
      warn "گزینه نامعتبر است. لطفاً عدد بین 0 تا ${#versions[@]} وارد کنید."
    fi
  done
  
  echo "$selected_version"
}

download_kafka() {
  local kafka_version="$1"
  local scala_version="$2"
  local url="https://downloads.apache.org/kafka/${kafka_version}/kafka_${scala_version}-${kafka_version}.tgz"
  local sha_url="${url}.sha512"

  # چک فضای دیسک قبل از دانلود
  check_disk_space "/tmp" 1
  check_disk_space "${KAFKA_BASE_DIR}" 2

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local tgz="${tmp_dir}/kafka.tgz"
  local sha="${tmp_dir}/kafka.tgz.sha512"

  info "دانلود Kafka ${kafka_version} ..."
  
  # تلاش برای دانلود با retry و fallback به mirror
  local download_success=0
  local mirrors=(
    "https://downloads.apache.org/kafka/${kafka_version}/kafka_${scala_version}-${kafka_version}.tgz"
    "https://archive.apache.org/dist/kafka/${kafka_version}/kafka_${scala_version}-${kafka_version}.tgz"
  )
  
  for mirror_url in "${mirrors[@]}"; do
    if curl -fsSL --connect-timeout 30 --max-time 600 --retry 3 --retry-delay 5 -o "${tgz}" "${mirror_url}" >>"$LOG_FILE" 2>&1; then
      download_success=1
      url="$mirror_url"
      break
    fi
    warn "دانلود از ${mirror_url} ناموفق بود. تلاش با mirror دیگر..."
  done
  
  if ((download_success == 0)); then
    rm -rf "$tmp_dir"
    die "دانلود Kafka از تمام mirror ها ناموفق بود. اتصال اینترنت را چک کنید."
  fi
  
  # دانلود checksum - تلاش با چند فرمت مختلف
  sha_url="${url}.sha512"
  local sha_downloaded=0
  
  if curl -fsSL --retry 3 --retry-delay 2 -o "${sha}" "${sha_url}" >>"$LOG_FILE" 2>&1; then
    sha_downloaded=1
  else
    # تلاش با نام دیگر
    local sha_alt_url="${url}.sha512.asc"
    if curl -fsSL --retry 3 --retry-delay 2 -o "${sha}" "${sha_alt_url}" >>"$LOG_FILE" 2>&1; then
      sha_downloaded=1
    fi
  fi
  
  if ((sha_downloaded == 1)); then
    info "اعتبارسنجی sha512 ..."
    
    # چک وجود ابزار sha512sum
    if ! have_cmd sha512sum; then
      warn "ابزار sha512sum موجود نیست. نصب..."
      apt-get install -y coreutils >>"$LOG_FILE" 2>&1 || {
        warn "نصب sha512sum ناموفق بود. بدون اعتبارسنجی ادامه می‌دهیم."
        sha_downloaded=0
      }
    fi
    
    if ((sha_downloaded == 1)); then
      # محاسبه SHA512 فایل دانلود شده
      local computed_hash
      computed_hash=$(sha512sum "${tgz}" 2>/dev/null | awk '{print $1}' | tr '[:upper:]' '[:lower:]' || echo "")
      
      if [[ -z "$computed_hash" ]] || [[ ${#computed_hash} -ne 128 ]]; then
        warn "محاسبه SHA512 فایل دانلود شده ناموفق بود. فایل ممکن است خراب باشد."
        read -r -p "آیا می‌خواهید بدون اعتبارسنجی ادامه دهید؟ (yes/no): " skip_verify || skip_verify="no"
        if [[ "$skip_verify" != "yes" ]]; then
          rm -rf "$tmp_dir"
          die "اعتبارسنجی لغو شد."
        fi
        warn "ادامه بدون اعتبارسنجی (ریسک امنیتی!)"
      else
        # خواندن hash از فایل SHA512 (می‌تواند فرمت‌های مختلف داشته باشد)
        local expected_hash=""
        local sha_lines
        sha_lines=$(wc -l < "${sha}" 2>/dev/null || echo "0")
        
        # روش 1: فقط hash در یک خط (بدون نام فایل)
        if ((sha_lines == 1)); then
          expected_hash=$(cat "${sha}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo "")
          # اگر فقط hash است و طول درست دارد
          if [[ ${#expected_hash} -eq 128 ]]; then
            expected_hash="${expected_hash:0:128}"
          fi
        fi
        
        # روش 2: فرمت "hash  filename" یا "hash *filename"
        if [[ -z "$expected_hash" ]] || [[ ${#expected_hash} -ne 128 ]]; then
          expected_hash=$(awk '{print $1}' "${sha}" 2>/dev/null | head -n1 | tr -d '[:space:*]' | tr '[:upper:]' '[:lower:]' || echo "")
          # اگر hash بیشتر از 128 کاراکتر است (ممکن است PGP signature باشد)، فقط 128 کاراکتر اول را بگیر
          if [[ ${#expected_hash} -gt 128 ]]; then
            expected_hash="${expected_hash:0:128}"
          fi
        fi
        
        # روش 3: جستجو برای الگوی SHA512 (128 کاراکتر hexadecimal)
        if [[ -z "$expected_hash" ]] || [[ ${#expected_hash} -ne 128 ]]; then
          expected_hash=$(grep -oE '[a-f0-9]{128}' "${sha}" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' || echo "")
        fi
        
        # مقایسه
        if [[ -n "$expected_hash" ]] && [[ ${#expected_hash} -eq 128 ]] && [[ "$computed_hash" == "$expected_hash" ]]; then
          ok "اعتبارسنجی SHA512 موفق ✓"
        elif [[ -z "$expected_hash" ]] || [[ ${#expected_hash} -ne 128 ]]; then
          warn "نتوانستم hash را از فایل SHA512 استخراج کنم. فرمت غیرمنتظره است."
          warn "محاسبه شده: ${computed_hash:0:16}..."
          warn "محتوای فایل SHA512 (10 کاراکتر اول): $(head -c 50 "${sha}" 2>/dev/null || echo "خالی")"
          read -r -p "آیا می‌خواهید بدون اعتبارسنجی ادامه دهید؟ (yes/no): " skip_verify || skip_verify="no"
          if [[ "$skip_verify" != "yes" ]]; then
            rm -rf "$tmp_dir"
            die "اعتبارسنجی لغو شد."
          fi
          warn "ادامه بدون اعتبارسنجی (ریسک امنیتی!)"
        else
          warn "هش‌ها مطابقت ندارند!"
          warn "محاسبه شده: ${computed_hash:0:32}..."
          warn "انتظار می‌رفت: ${expected_hash:0:32}..."
          read -r -p "فایل ممکن است خراب باشد. آیا می‌خواهید ادامه دهید؟ (yes/no): " force_continue || force_continue="no"
          if [[ "$force_continue" != "yes" ]]; then
            rm -rf "$tmp_dir"
            die "اعتبارسنجی ناموفق بود. دانلود مجدد توصیه می‌شود."
          fi
          warn "ادامه با فایل مشکوک (ریسک امنیتی!)"
        fi
      fi
    fi
  else
    warn "دانلود فایل sha512 ناموفق بود."
    read -r -p "آیا می‌خواهید بدون اعتبارسنجی ادامه دهید؟ (yes/no): " skip_verify || skip_verify="no"
    if [[ "$skip_verify" != "yes" ]]; then
      rm -rf "$tmp_dir"
      die "اعتبارسنجی لغو شد."
    fi
    warn "ادامه بدون اعتبارسنجی (ریسک امنیتی!)"
  fi

  info "استخراج ..."
  local dest="${KAFKA_BASE_DIR}/kafka_${scala_version}-${kafka_version}"
  if [[ -d "$dest" ]]; then
    ok "این نسخه از قبل نصب شده: $dest"
  else
    if ! tar -xzf "${tgz}" -C "${KAFKA_BASE_DIR}" >>"$LOG_FILE" 2>&1; then
      rm -rf "$tmp_dir"
      die "استخراج فایل Kafka ناموفق بود. ممکن است فایل خراب باشد."
    fi
    run "chown -R ${KAFKA_USER}:${KAFKA_GROUP} '${dest}'"
  fi

  run "ln -sfn '${dest}' '${KAFKA_SYMLINK}'"
  ok "Kafka آماده است: ${KAFKA_SYMLINK}"

  run "rm -rf '${tmp_dir}'"
}

ensure_systemd_unit() {
  info "ساخت/به‌روزرسانی سرویس systemd ..."

  cat >"$SYSTEMD_UNIT" <<'UNIT'
[Unit]
Description=Apache Kafka (KRaft)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kafka
Group=kafka
EnvironmentFile=-/etc/default/kafka
WorkingDirectory=/opt/kafka/current
ExecStart=/opt/kafka/current/bin/kafka-server-start.sh /etc/kafka/server.properties
ExecStop=/opt/kafka/current/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/kafka /var/log/kafka /etc/kafka
CapabilityBoundingSet=
AmbientCapabilities=
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
UNIT

  run "chmod 0644 '$SYSTEMD_UNIT'"
  run "systemctl daemon-reload"
  ok "سرویس systemd آماده شد."
}

write_env_file() {
  # قابل تنظیم: JVM opts و heap
  local heap_mb="$1"
  info "تنظیم فایل ${KAFKA_ENV_FILE} ..."
  cat >"$KAFKA_ENV_FILE" <<EOF
# Generated by ${SCRIPT_NAME} at $(date -Is)
KAFKA_HEAP_OPTS="-Xms${heap_mb}m -Xmx${heap_mb}m"
KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -Djava.awt.headless=true"
EOF
  run "chmod 0644 '$KAFKA_ENV_FILE'"
}

generate_server_properties() {
  local node_id="$1"
  local roles="$2"                       # "broker,controller" or "broker" or "controller"
  local controller_listener_name="$3"    # e.g. CONTROLLER
  local controller_port="$4"
  local broker_port="$5"
  local advertised_host="$6"             # hostname/ip for clients
  local controller_quorum_voters="$7"    # e.g. "1@host1:9093,2@host2:9093,3@host3:9093"
  local data_dir="$8"
  local log_dir="$9"
  local bind_ip="${10}"                  # recommended private IP
  local enable_sasl_scram="${11}"        # "yes"/"no"
  local admin_user="${12:-}"
  local admin_pass="${13:-}"

  validate_hostname_or_ip "$advertised_host"
  validate_hostname_or_ip "$bind_ip"

  port_free_or_die "$controller_port"
  port_free_or_die "$broker_port"

  info "نوشتن فایل تنظیمات ${KAFKA_ETC_DIR}/server.properties ..."

  # Listener strategy:
  # - CONTROLLER: bound to bind_ip:controller_port
  # - INTERNAL:   broker binds to bind_ip:broker_port (cluster/internal)
  # - EXTERNAL:   advertised to clients as advertised_host:broker_port
  #
  # By default we keep PLAINTEXT. If SASL enabled => SASL_PLAINTEXT (TLS can be added later)
  local broker_proto="PLAINTEXT"
  if [[ "$enable_sasl_scram" == "yes" ]]; then
    broker_proto="SASL_PLAINTEXT"
  fi

  cat >"${KAFKA_ETC_DIR}/server.properties" <<EOF
############################# Server Basics #############################
process.roles=${roles}
node.id=${node_id}

############################# KRaft #############################
controller.listener.names=${controller_listener_name}
controller.quorum.voters=${controller_quorum_voters}

############################# Socket Server Settings #############################
listeners=${controller_listener_name}://${bind_ip}:${controller_port},INTERNAL://${bind_ip}:${broker_port}
listener.security.protocol.map=${controller_listener_name}:PLAINTEXT,INTERNAL:${broker_proto}
inter.broker.listener.name=INTERNAL
advertised.listeners=INTERNAL://${advertised_host}:${broker_port}

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

############################# Log Basics #############################
log.dirs=${data_dir}
num.partitions=3
num.recovery.threads.per.data.dir=1

############################# Internal Topic Settings #############################
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2

############################# Log Retention Policy #############################
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

############################# Group Coordinator #############################
group.initial.rebalance.delay.ms=0

############################# KRaft/Metadata #############################
metadata.log.dir=${data_dir}/metadata

############################# Security (optional) #############################
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
allow.everyone.if.no.acl.found=false
super.users=User:admin

EOF

  # اگر SASL فعال باشد، تنظیمات تکمیلی را اضافه می‌کنیم.
  if [[ "$enable_sasl_scram" == "yes" ]]; then
    cat >>"${KAFKA_ETC_DIR}/server.properties" <<EOF
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
listener.name.internal.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \\
  username="${admin_user}" \\
  password="${admin_pass}";
EOF
  fi

  run "chown ${KAFKA_USER}:${KAFKA_GROUP} '${KAFKA_ETC_DIR}/server.properties'"
  run "chmod 0640 '${KAFKA_ETC_DIR}/server.properties'"
}

format_storage() {
  local cluster_id="$1"
  info "فرمت کردن storage برای KRaft (یک‌بار برای هر نود) ..."
  if [[ ! -x "${KAFKA_SYMLINK}/bin/kafka-storage.sh" ]]; then
    die "ابزار kafka-storage.sh پیدا نشد. آیا Kafka دانلود/نصب شده؟"
  fi

  # اگر قبلاً فرمت شده باشد، دوباره فرمت نمی‌کنیم.
  # در KRaft وجود meta.properties نشانه فرمت شدن است.
  local meta_file="${KAFKA_DATA_DIR_DEFAULT}/meta.properties"
  if [[ -f "${meta_file}" ]] || [[ -f "${KAFKA_DATA_DIR_DEFAULT}/metadata/meta.properties" ]]; then
    warn "به نظر می‌رسد این نود قبلاً فرمت شده است (meta.properties موجود است). از فرمت مجدد صرف‌نظر شد."
    return 0
  fi

  run "sudo -u ${KAFKA_USER} '${KAFKA_SYMLINK}/bin/kafka-storage.sh' format -t '${cluster_id}' -c '${KAFKA_ETC_DIR}/server.properties'"
  ok "storage فرمت شد."
}

start_enable_service() {
  info "فعال‌سازی و استارت سرویس Kafka ..."
  run "systemctl enable kafka"
  run "systemctl restart kafka"
  run "sleep 2"
  run "systemctl --no-pager --full status kafka"
  ok "Kafka اجرا شد."
}

stop_service() {
  if systemctl is-active --quiet kafka; then
    info "توقف سرویس Kafka ..."
    run "systemctl stop kafka"
    ok "متوقف شد."
  else
    ok "Kafka در حال اجرا نیست."
  fi
}

cluster_status() {
  echo
  info "═══════════════════════════════════════════════════"
  info "         وضعیت کلاستر و سرویس Kafka              "
  info "═══════════════════════════════════════════════════"
  
  # 1. وضعیت سرویس
  echo
  info "═══ وضعیت سرویس systemd ═══"
  if systemctl is-active --quiet kafka; then
    ok "✓ سرویس Kafka در حال اجرا است"
  else
    warn "✗ سرویس Kafka اجرا نیست!"
  fi
  systemctl --no-pager --full status kafka || true
  
  # 2. چک پورت‌ها
  echo
  info "═══ پورت‌های در حال گوش دادن ═══"
  local ports_found=0
  if ss -lntp 2>/dev/null | grep -E ':9092\s' >/dev/null; then
    ok "✓ پورت 9092 (Broker) باز است"
    ss -lntp 2>/dev/null | grep ':9092' || true
    ports_found=1
  else
    warn "✗ پورت 9092 (Broker) باز نیست"
  fi
  
  if ss -lntp 2>/dev/null | grep -E ':9093\s' >/dev/null; then
    ok "✓ پورت 9093 (Controller) باز است"
    ss -lntp 2>/dev/null | grep ':9093' || true
    ports_found=1
  else
    warn "✗ پورت 9093 (Controller) باز نیست"
  fi
  
  if ((ports_found == 0)); then
    warn "هیچ پورت Kafka باز نیست. سرویس ممکن است اجرا نشده باشد."
  fi
  
  # 3. اطلاعات نود
  echo
  info "═══ اطلاعات نود ═══"
  if [[ -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    local node_id roles
    node_id=$(grep "^node.id=" "${KAFKA_ETC_DIR}/server.properties" 2>/dev/null | cut -d= -f2 || echo "نامشخص")
    roles=$(grep "^process.roles=" "${KAFKA_ETC_DIR}/server.properties" 2>/dev/null | cut -d= -f2 || echo "نامشخص")
    echo "  Node ID: $node_id"
    echo "  Roles: $roles"
    
    local cluster_id
    cluster_id=$(load_cluster_id)
    if [[ -n "$cluster_id" ]]; then
      echo "  Cluster ID: $cluster_id"
    fi
  else
    warn "فایل تنظیمات یافت نشد"
  fi
  
  # 4. وضعیت Quorum
  echo
  info "═══ وضعیت KRaft Quorum ═══"
  if [[ -x "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" ]] && systemctl is-active --quiet kafka; then
    # تلاش برای گرفتن وضعیت quorum
    if "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" --bootstrap-server "127.0.0.1:${BROKER_PORT_DEFAULT}" describe --status 2>/dev/null; then
      ok "اطلاعات quorum با موفقیت دریافت شد"
    else
      warn "نتوانستم وضعیت quorum را دریافت کنم (ممکن است سرویس هنوز آماده نباشد یا ACL فعال باشد)"
    fi
    
    echo
    echo "لیست اعضای quorum:"
    "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" --bootstrap-server "127.0.0.1:${BROKER_PORT_DEFAULT}" describe --replication 2>/dev/null || warn "نتوانستم اطلاعات replication را دریافت کنم"
  else
    if [[ ! -x "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" ]]; then
      warn "ابزار kafka-metadata-quorum.sh موجود نیست (احتمالاً نصب ناقص)"
    else
      warn "سرویس Kafka اجرا نیست، نمی‌توانم وضعیت quorum را چک کنم"
    fi
  fi
  
  # 5. Topics (اگر موجود باشد)
  echo
  info "═══ لیست Topics ═══"
  if [[ -x "${KAFKA_SYMLINK}/bin/kafka-topics.sh" ]] && systemctl is-active --quiet kafka; then
    local topic_count
    topic_count=$("${KAFKA_SYMLINK}/bin/kafka-topics.sh" --bootstrap-server "127.0.0.1:${BROKER_PORT_DEFAULT}" --list 2>/dev/null | wc -l || echo "0")
    echo "تعداد topics: $topic_count"
    
    if ((topic_count > 0)) && ((topic_count < 20)); then
      "${KAFKA_SYMLINK}/bin/kafka-topics.sh" --bootstrap-server "127.0.0.1:${BROKER_PORT_DEFAULT}" --list 2>/dev/null || true
    elif ((topic_count >= 20)); then
      echo "(بیش از 20 topic وجود دارد - نمایش داده نشد)"
    fi
  else
    echo "سرویس اجرا نیست یا ابزار موجود نیست"
  fi
  
  # 6. منابع سیستم
  echo
  info "═══ منابع سیستم ═══"
  echo "فضای دیسک:"
  df -h "${KAFKA_DATA_DIR_DEFAULT}" 2>/dev/null || df -h /var/lib 2>/dev/null || true
  echo
  echo "حافظه:"
  free -h | head -2 || true
  echo
  echo "CPU Load:"
  uptime || true
  
  # 7. Java Process
  echo
  info "═══ Java Process ═══"
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    local kafka_pid
    kafka_pid=$(pgrep -f "kafka.Kafka" | head -1)
    echo "✓ Kafka process در حال اجرا (PID: $kafka_pid)"
    
    # نمایش استفاده CPU/Memory
    ps -p "$kafka_pid" -o pid,user,%cpu,%mem,vsz,rss,cmd 2>/dev/null || true
  else
    warn "✗ هیچ پروسه Kafka یافت نشد"
  fi
  
  echo
  ok "نمایش وضعیت تمام شد."
}

troubleshoot_check_disk() {
  echo
  info "═══ چک فضای دیسک ═══"
  local kafka_disk_usage
  kafka_disk_usage=$(df -h "${KAFKA_DATA_DIR_DEFAULT}" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
  
  if [[ -n "$kafka_disk_usage" ]] && ((kafka_disk_usage > 90)); then
    warn "فضای دیسک Kafka ${kafka_disk_usage}% پر است! (بحرانی)"
    echo "راه‌حل‌های پیشنهادی:"
    echo "  1. کاهش log.retention.hours در server.properties"
    echo "  2. پاک کردن لاگ‌های قدیمی دستی"
    echo "  3. افزایش فضای دیسک"
    
    read -r -p "آیا می‌خواهید لاگ‌های قدیمی‌تر از 7 روز را پاک کنم؟ (yes/no): " clean_logs
    if [[ "$clean_logs" == "yes" ]]; then
      info "پاک کردن لاگ‌های قدیمی..."
      find "${KAFKA_DATA_DIR_DEFAULT}" -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
      find "${KAFKA_LOG_DIR_DEFAULT}" -type f -name "*.log.*" -mtime +7 -delete 2>/dev/null || true
      ok "لاگ‌های قدیمی پاک شدند"
    fi
  else
    df -h "${KAFKA_DATA_DIR_DEFAULT}" 2>/dev/null || df -h /var/lib 2>/dev/null || true
  fi
}

troubleshoot_check_memory() {
  echo
  info "═══ چک حافظه و CPU ═══"
  free -h || true
  uptime || true
  
  # چک اگر Java out of memory خورده
  if journalctl -u kafka --no-pager -n 500 2>/dev/null | grep -qi "OutOfMemoryError"; then
    warn "خطای OutOfMemoryError در لاگ‌ها یافت شد!"
    echo "راه‌حل: افزایش KAFKA_HEAP_OPTS در ${KAFKA_ENV_FILE}"
    
    read -r -p "آیا می‌خواهید heap را به 4096MB افزایش دهم؟ (yes/no): " increase_heap
    if [[ "$increase_heap" == "yes" ]]; then
      sed -i 's/KAFKA_HEAP_OPTS=.*/KAFKA_HEAP_OPTS="-Xms4096m -Xmx4096m"/' "${KAFKA_ENV_FILE}"
      ok "Heap به 4096MB تغییر یافت. سرویس را restart کنید."
    fi
  fi
}

troubleshoot_check_ports() {
  echo
  info "═══ چک پورت‌ها ═══"
  
  local kafka_ports=("9092" "9093")
  local port_issues=0
  
  for port in "${kafka_ports[@]}"; do
    if ss -lnt "( sport = :$port )" 2>/dev/null | grep -q ":$port"; then
      local pid
      pid=$(ss -lntp "( sport = :$port )" 2>/dev/null | grep ":$port" | awk '{print $6}' | grep -oP 'pid=\K[0-9]+' | head -1)
      echo "✓ پورت $port در حال استفاده (PID: ${pid:-unknown})"
    else
      warn "✗ پورت $port باز نیست! Kafka ممکن است اجرا نشده باشد."
      port_issues=1
    fi
  done
  
  # چک پورت‌های اشغال توسط پروسه دیگر
  for port in "${kafka_ports[@]}"; do
    local blocking_pid
    blocking_pid=$(lsof -ti ":$port" 2>/dev/null | grep -v "$(pgrep -f kafka)" | head -1)
    if [[ -n "$blocking_pid" ]]; then
      warn "پورت $port توسط پروسه دیگری اشغال شده (PID: $blocking_pid)"
      local blocking_cmd
      blocking_cmd=$(ps -p "$blocking_pid" -o comm= 2>/dev/null)
      echo "  پروسه: ${blocking_cmd:-unknown}"
      
      read -r -p "آیا می‌خواهید این پروسه را kill کنم؟ (yes/no): " kill_proc
      if [[ "$kill_proc" == "yes" ]]; then
        kill -9 "$blocking_pid" 2>/dev/null || true
        ok "پروسه $blocking_pid کشته شد"
      fi
    fi
  done
  
  return $port_issues
}

troubleshoot_check_permissions() {
  echo
  info "═══ چک دسترسی‌ها (Permissions) ═══"
  
  local dirs=("${KAFKA_DATA_DIR_DEFAULT}" "${KAFKA_LOG_DIR_DEFAULT}" "${KAFKA_ETC_DIR}")
  local perm_issues=0
  
  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      warn "دایرکتوری $dir وجود ندارد!"
      perm_issues=1
    elif [[ ! -r "$dir" ]] || [[ ! -w "$dir" ]]; then
      warn "مشکل دسترسی در $dir"
      perm_issues=1
    else
      local owner
      owner=$(stat -c '%U:%G' "$dir" 2>/dev/null)
      if [[ "$owner" != "${KAFKA_USER}:${KAFKA_GROUP}" ]]; then
        warn "مالک نادرست: $dir (مالک فعلی: $owner، باید باشد: ${KAFKA_USER}:${KAFKA_GROUP})"
        perm_issues=1
      else
        echo "✓ $dir (مالک: $owner)"
      fi
    fi
  done
  
  if ((perm_issues > 0)); then
    read -r -p "آیا می‌خواهید مشکلات دسترسی را خودکار رفع کنم؟ (yes/no): " fix_perms
    if [[ "$fix_perms" == "yes" ]]; then
      for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
        chown -R "${KAFKA_USER}:${KAFKA_GROUP}" "$dir" 2>/dev/null || true
        chmod 0750 "$dir" 2>/dev/null || true
      done
      ok "دسترسی‌ها اصلاح شدند"
    fi
  fi
}

troubleshoot_check_service() {
  echo
  info "═══ چک وضعیت سرویس ═══"
  
  if systemctl is-active --quiet kafka; then
    ok "✓ سرویس Kafka در حال اجرا است"
    systemctl status kafka --no-pager -l || true
  else
    warn "✗ سرویس Kafka اجرا نیست!"
    
    # بررسی علت
    if journalctl -u kafka --no-pager -n 50 2>/dev/null | grep -qi "failed"; then
      warn "سرویس با خطا متوقف شده است. آخرین لاگ‌ها:"
      journalctl -u kafka --no-pager -n 30 || true
    fi
    
    read -r -p "آیا می‌خواهید سرویس را restart کنم؟ (yes/no): " restart_svc
    if [[ "$restart_svc" == "yes" ]]; then
      systemctl restart kafka || true
      sleep 3
      systemctl status kafka --no-pager || true
    fi
  fi
}

troubleshoot_check_config() {
  echo
  info "═══ چک تنظیمات ═══"
  
  if [[ ! -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    warn "فایل ${KAFKA_ETC_DIR}/server.properties وجود ندارد!"
    return 1
  fi
  
  # بررسی فیلدهای ضروری
  local required_fields=("process.roles" "node.id" "controller.quorum.voters" "listeners")
  local config_issues=0
  
  for field in "${required_fields[@]}"; do
    if ! grep -q "^${field}=" "${KAFKA_ETC_DIR}/server.properties"; then
      warn "✗ فیلد ${field} در تنظیمات یافت نشد!"
      config_issues=1
    else
      local value
      value=$(grep "^${field}=" "${KAFKA_ETC_DIR}/server.properties" | head -1)
      echo "✓ $value"
    fi
  done
  
  # چک node.id تکراری
  local node_id
  node_id=$(grep "^node.id=" "${KAFKA_ETC_DIR}/server.properties" | cut -d= -f2)
  if [[ -z "$node_id" ]]; then
    warn "node.id تنظیم نشده است!"
    config_issues=1
  fi
  
  # نمایش listeners
  echo
  echo "تنظیمات مهم:"
  grep -E '^(process.roles|node.id|controller.quorum.voters|listeners|advertised.listeners|inter.broker.listener.name|log.dirs)' "${KAFKA_ETC_DIR}/server.properties" 2>/dev/null || true
  
  return $config_issues
}

troubleshoot_check_network() {
  echo
  info "═══ چک شبکه و اتصال به سایر نودها ═══"
  
  if [[ ! -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    warn "تنظیمات یافت نشد، نمی‌توانم نودها را چک کنم."
    return 1
  fi
  
  local quorum_voters
  quorum_voters=$(grep "^controller.quorum.voters=" "${KAFKA_ETC_DIR}/server.properties" | cut -d= -f2)
  
  if [[ -z "$quorum_voters" ]]; then
    warn "controller.quorum.voters تنظیم نشده است!"
    return 1
  fi
  
  echo "بررسی اتصال به نودهای کلاستر:"
  echo "$quorum_voters" | tr ',' '\n' | while IFS='@' read -r node_id host_port; do
    local host="${host_port%:*}"
    local port="${host_port##*:}"
    
    echo -n "  نود $node_id ($host:$port): "
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
      echo "✓ قابل دسترس"
    else
      echo "✗ غیرقابل دسترس"
      warn "    نمی‌توانم به $host:$port متصل شوم. فایروال یا شبکه را چک کنید."
    fi
  done
}

troubleshoot_check_java() {
  echo
  info "═══ چک Java ═══"
  
  if ! have_cmd java; then
    warn "Java نصب نیست!"
    read -r -p "آیا می‌خواهید Java را نصب کنم؟ (yes/no): " install_java
    if [[ "$install_java" == "yes" ]]; then
      apt_install_prereqs
    fi
    return 1
  fi
  
  local java_version
  java_version=$(java -version 2>&1 | head -1)
  echo "✓ $java_version"
  
  # چک JAVA_HOME
  if [[ -z "${JAVA_HOME:-}" ]]; then
    warn "متغیر JAVA_HOME تنظیم نشده است (معمولاً مشکلی نیست)"
  fi
}

troubleshoot_check_logs() {
  echo
  info "═══ آخرین لاگ‌های مهم ═══"
  
  # جستجوی خطاهای رایج
  local common_errors=(
    "ERROR"
    "FATAL"
    "OutOfMemoryError"
    "Connection refused"
    "Unable to connect"
    "Authentication failed"
    "Permission denied"
  )
  
  echo "جستجو در لاگ‌ها برای خطاهای رایج:"
  for error in "${common_errors[@]}"; do
    local count
    count=$(journalctl -u kafka --no-pager -n 1000 2>/dev/null | grep -c "$error" || echo "0")
    if ((count > 0)); then
      warn "  '$error' یافت شد: $count بار"
    fi
  done
  
  echo
  echo "آخرین 50 خط لاگ:"
  journalctl -u kafka --no-pager -n 50 || true
}

troubleshoot_check_time_sync() {
  echo
  info "═══ چک همگام‌سازی زمان ═══"
  
  if have_cmd timedatectl; then
    timedatectl status || true
    
    if ! timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
      warn "ساعت سیستم همگام نیست! این می‌تواند مشکل کلاستر ایجاد کند."
      
      read -r -p "آیا می‌خواهید NTP را فعال کنم؟ (yes/no): " enable_ntp
      if [[ "$enable_ntp" == "yes" ]]; then
        timedatectl set-ntp true 2>/dev/null || true
        ok "NTP فعال شد"
      fi
    fi
  else
    echo "زمان فعلی: $(date)"
  fi
}

troubleshoot_fix_common_issues() {
  echo
  info "═══ رفع خودکار مشکلات رایج ═══"
  
  local fixes_applied=0
  
  # 1. رفع فایل‌های قفل
  if [[ -f "${KAFKA_DATA_DIR_DEFAULT}/.lock" ]]; then
    warn "فایل قفل پیدا شد. حذف می‌شود..."
    rm -f "${KAFKA_DATA_DIR_DEFAULT}/.lock"
    fixes_applied=1
  fi
  
  # 2. رفع ulimit پایین
  local current_limit
  current_limit=$(su -s /bin/bash -c 'ulimit -n' "${KAFKA_USER}" 2>/dev/null || echo "0")
  if ((current_limit < 65536)); then
    warn "محدودیت فایل باز (ulimit) خیلی پایین است: $current_limit"
    echo "kafka soft nofile 100000" >> /etc/security/limits.conf
    echo "kafka hard nofile 100000" >> /etc/security/limits.conf
    ok "ulimit در /etc/security/limits.conf تنظیم شد (نیاز به restart سرویس)"
    fixes_applied=1
  fi
  
  # 3. رفع مشکل systemd که ممکن است failed باشد
  if systemctl is-failed --quiet kafka 2>/dev/null; then
    warn "سرویس Kafka در حالت failed است. reset می‌کنم..."
    systemctl reset-failed kafka
    fixes_applied=1
  fi
  
  if ((fixes_applied > 0)); then
    ok "تعدادی مشکل رفع شد. پیشنهاد می‌شود سرویس را restart کنید."
  else
    ok "مشکل رایجی یافت نشد."
  fi
}

troubleshoot() {
  echo
  info "═══════════════════════════════════════════════════"
  info "   عیب‌یابی جامع Kafka با رفع خودکار مشکلات    "
  info "═══════════════════════════════════════════════════"
  
  troubleshoot_check_java
  troubleshoot_check_disk
  troubleshoot_check_memory
  troubleshoot_check_service
  troubleshoot_check_ports
  troubleshoot_check_permissions
  troubleshoot_check_config
  troubleshoot_check_network
  troubleshoot_check_time_sync
  troubleshoot_check_logs
  troubleshoot_fix_common_issues
  
  echo
  info "═══ اطلاعات اضافی ═══"
  echo "- لاگ اسکریپت bootstrap: $LOG_FILE"
  echo "- لاگ‌های Kafka: journalctl -u kafka -f"
  echo "- دایرکتوری داده: ${KAFKA_DATA_DIR_DEFAULT}"
  echo "- فایل تنظیمات: ${KAFKA_ETC_DIR}/server.properties"
  
  echo
  ok "عیب‌یابی کامل شد."
}

secure_firewall_optional() {
  local allow_subnet="$1"   # e.g. 10.0.0.0/8
  local broker_port="$2"
  local controller_port="$3"

  if ! have_cmd ufw; then
    warn "ufw نصب نیست؛ از تنظیم فایروال صرف‌نظر شد."
    return 0
  fi

  info "اعمال قوانین UFW (اختیاری) ..."
  # سیاست: فقط از subnet مشخص شده به پورت‌ها اجازه بده
  # (اگر UFW قبلاً فعال نیست، فعال‌سازی را به کاربر واگذار می‌کنیم)
  run "ufw allow from '${allow_subnet}' to any port ${broker_port} proto tcp"
  run "ufw allow from '${allow_subnet}' to any port ${controller_port} proto tcp"
  ok "قوانین UFW اضافه شد. اگر UFW غیرفعال است، با 'ufw enable' فعالش کنید (با احتیاط)."
}

save_cluster_id() {
  local cluster_id="$1"
  run "mkdir -p '${KAFKA_ETC_DIR}'"
  echo "$cluster_id" >"${KAFKA_ETC_DIR}/cluster.id"
  run "chmod 0600 '${KAFKA_ETC_DIR}/cluster.id'"
  ok "cluster.id ذخیره شد در ${KAFKA_ETC_DIR}/cluster.id"
}

load_cluster_id() {
  if [[ -f "${KAFKA_ETC_DIR}/cluster.id" ]]; then
    cat "${KAFKA_ETC_DIR}/cluster.id"
  else
    echo ""
  fi
}

gen_cluster_id() {
  if [[ -x "${KAFKA_SYMLINK}/bin/kafka-storage.sh" ]]; then
    sudo -u "$KAFKA_USER" "${KAFKA_SYMLINK}/bin/kafka-storage.sh" random-uuid
  else
    # fallback
    if have_cmd uuidgen; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
  fi
}

menu_header() {
  clear || true
  echo "==============================================="
  echo "   راه‌انداز کلاستر Kafka (Ubuntu / KRaft)     "
  echo "==============================================="
  echo "لاگ: ${LOG_FILE}"
  echo
}

common_prepare() {
  need_root
  log_init
  assert_ubuntu
  require_tools

  # پکیج‌ها را در صورت نیاز نصب می‌کنیم (اگر جاوا نبود، پیشنهاد نصب می‌دهیم)
  if ! have_cmd java; then
    warn "Java پیدا نشد. پیشنهاد: گزینه 'نصب/آماده‌سازی' را اجرا کنید."
  fi

  ensure_user
  ensure_dirs "$KAFKA_DATA_DIR_DEFAULT" "$KAFKA_LOG_DIR_DEFAULT"
  ensure_systemd_unit
}

action_install_prepare() {
  need_root
  log_init
  assert_ubuntu
  
  echo
  info "═══════════════════════════════════════════════════"
  info "      نصب و آماده‌سازی Kafka با چک کامل         "
  info "═══════════════════════════════════════════════════"
  
  # چک پیش‌نیازهای سیستم قبل از نصب
  echo
  info "═══ چک پیش‌نیازهای سیستم ═══"
  check_disk_space "/opt" 3
  check_disk_space "/var" 10
  check_memory 2048
  
  echo
  info "═══ بررسی دسترسی اینترنت و DNS ═══"
  check_internet_access
  fix_dns_if_needed
  
  echo
  info "═══ نصب پکیج‌های پیش‌نیاز ═══"
  apt_install_prereqs
  require_tools
  
  # تأیید نصب موفق Java
  if ! have_cmd java; then
    die "Java پس از نصب هنوز موجود نیست! مشکل در apt یا مخزن پکیج وجود دارد."
  fi
  
  local java_version
  java_version=$(java -version 2>&1 | head -1)
  ok "Java نصب شد: $java_version"
  
  echo
  info "═══ ایجاد کاربر و دایرکتوری‌ها ═══"
  ensure_user
  ensure_dirs "$KAFKA_DATA_DIR_DEFAULT" "$KAFKA_LOG_DIR_DEFAULT"
  
  # چک نهایی دسترسی‌ها
  if [[ ! -w "$KAFKA_BASE_DIR" ]]; then
    die "دایرکتوری $KAFKA_BASE_DIR قابل نوشتن نیست!"
  fi
  
  echo
  info "═══ دانلود و نصب Kafka ═══"
  local kafka_ver scala_ver
  
  # دریافت خودکار نسخه‌های موجود
  kafka_ver="$(select_kafka_version)"
  
  if [[ -z "$kafka_ver" ]]; then
    warn "نسخه انتخاب نشد. از نسخه پیش‌فرض استفاده می‌کنم."
    kafka_ver="$KAFKA_VERSION_DEFAULT"
  fi
  
  # چک نسخه معتبر
  if [[ ! "$kafka_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "فرمت نسخه نامعتبر است ($kafka_ver). از نسخه پیش‌فرض استفاده می‌کنم."
    kafka_ver="$KAFKA_VERSION_DEFAULT"
  fi
  
  info "نسخه انتخاب شده: $kafka_ver"
  scala_ver="$(prompt_default 'نسخه Scala (برای پکیج Kafka، معمولاً 2.13)' "$SCALA_VERSION_DEFAULT")"
  
  download_kafka "$kafka_ver" "$scala_ver"
  
  # تأیید نصب موفق
  if [[ ! -d "${KAFKA_SYMLINK}" ]]; then
    die "نصب Kafka ناموفق بود. دایرکتوری ${KAFKA_SYMLINK} وجود ندارد."
  fi
  
  if [[ ! -x "${KAFKA_SYMLINK}/bin/kafka-server-start.sh" ]]; then
    die "فایل‌های اجرایی Kafka یافت نشدند. نصب ناقص است."
  fi
  
  ok "Kafka نصب شد: ${KAFKA_SYMLINK}"
  
  echo
  info "═══ ایجاد سرویس systemd ═══"
  ensure_systemd_unit
  
  # چک سرویس
  if [[ ! -f "$SYSTEMD_UNIT" ]]; then
    die "فایل سرویس systemd ایجاد نشد!"
  fi
  
  ok "سرویس systemd آماده شد"
  
  echo
  info "═══ چک نهایی ═══"
  echo "✓ Java: نصب شده"
  echo "✓ Kafka: نصب شده (${KAFKA_SYMLINK})"
  echo "✓ کاربر: ${KAFKA_USER}"
  echo "✓ سرویس: ${SYSTEMD_UNIT}"
  echo "✓ دایرکتوری داده: ${KAFKA_DATA_DIR_DEFAULT}"
  echo "✓ دایرکتوری لاگ: ${KAFKA_LOG_DIR_DEFAULT}"
  
  echo
  ok "═══════════════════════════════════════════════════"
  ok "   آماده‌سازی با موفقیت کامل شد!                 "
  ok "═══════════════════════════════════════════════════"
  echo
  echo "مراحل بعدی:"
  echo "  - برای سرور اولیه: گزینه 2 را انتخاب کنید"
  echo "  - برای سرور کمکی: گزینه 3 را انتخاب کنید"
}

action_setup_primary() {
  common_prepare

  info "راه‌اندازی به‌عنوان سرور اولیه (Primary) ..."

  local node_id roles controller_port broker_port advertised_host bind_ip heap_mb
  node_id="$(prompt_default 'node.id (عدد یکتا در کلاستر)' "1")"
  roles="broker,controller"
  controller_port="$(prompt_default 'پورت Controller (KRaft)' "$CONTROLLER_PORT_DEFAULT")"
  broker_port="$(prompt_default 'پورت Broker (Client)' "$BROKER_PORT_DEFAULT")"
  bind_ip="$(prompt_default 'IP برای Bind (ترجیحاً IP خصوصی همین سرور)' "127.0.0.1")"
  advertised_host="$(prompt_default 'Advertised Host برای کلاینت/نودها (DNS یا IP قابل دسترس)' "$bind_ip")"
  heap_mb="$(prompt_default 'Heap جاوا (MB) پیشنهاد 1024 تا 4096' "2048")"

  validate_hostname_or_ip "$bind_ip"
  validate_hostname_or_ip "$advertised_host"

  local quorum
  echo
  echo "فرمت controller.quorum.voters مثال: 1@10.0.0.1:9093,2@10.0.0.2:9093,3@10.0.0.3:9093"
  quorum="$(prompt_default 'controller.quorum.voters (حداقل 3 نود توصیه می‌شود)' "1@${advertised_host}:${controller_port}")"

  local enable_sasl
  enable_sasl="$(prompt_default 'فعال‌سازی امنیت SASL/SCRAM برای inter-broker؟ (yes/no)' "no")"
  local admin_user="admin"
  local admin_pass=""
  if [[ "$enable_sasl" == "yes" ]]; then
    admin_pass="$(prompt_secret 'رمز عبور کاربر admin (برای inter-broker SCRAM)')"
    [[ -n "$admin_pass" ]] || die "رمز عبور خالی مجاز نیست."
  fi

  write_env_file "$heap_mb"
  generate_server_properties "$node_id" "$roles" "CONTROLLER" "$controller_port" "$broker_port" "$advertised_host" "$quorum" "$KAFKA_DATA_DIR_DEFAULT" "$KAFKA_LOG_DIR_DEFAULT" "$bind_ip" "$enable_sasl" "$admin_user" "$admin_pass"

  local cluster_id
  cluster_id="$(gen_cluster_id)"
  [[ -n "$cluster_id" ]] || die "نتوانستم cluster id بسازم."
  save_cluster_id "$cluster_id"

  stop_service
  format_storage "$cluster_id"
  start_enable_service

  echo
  ok "Primary آماده شد."
  echo "برای اضافه کردن نودهای کمکی، این Cluster ID را استفاده کنید:"
  echo "  ${cluster_id}"
  echo

  local fw
  fw="$(prompt_default 'قانون UFW برای محدود کردن دسترسی به subnet اضافه شود؟ (yes/no)' "no")"
  if [[ "$fw" == "yes" ]]; then
    local subnet
    subnet="$(prompt_default 'subnet مجاز (مثال 10.0.0.0/8 یا 192.168.1.0/24)' "10.0.0.0/8")"
    secure_firewall_optional "$subnet" "$broker_port" "$controller_port"
  fi
}

action_setup_secondary() {
  common_prepare

  info "راه‌اندازی به‌عنوان سرور کمکی (Secondary) ..."

  local cluster_id node_id roles controller_port broker_port advertised_host bind_ip heap_mb
  cluster_id="$(prompt_default 'Cluster ID (از Primary بگیرید)' "$(load_cluster_id)")"
  [[ -n "$cluster_id" ]] || die "Cluster ID لازم است."

  node_id="$(prompt_default 'node.id (عدد یکتا در کلاستر)' "2")"
  roles="broker,controller"
  controller_port="$(prompt_default 'پورت Controller (KRaft)' "$CONTROLLER_PORT_DEFAULT")"
  broker_port="$(prompt_default 'پورت Broker (Client)' "$BROKER_PORT_DEFAULT")"
  bind_ip="$(prompt_default 'IP برای Bind (ترجیحاً IP خصوصی همین سرور)' "127.0.0.1")"
  advertised_host="$(prompt_default 'Advertised Host برای کلاینت/نودها (DNS یا IP قابل دسترس)' "$bind_ip")"
  heap_mb="$(prompt_default 'Heap جاوا (MB) پیشنهاد 1024 تا 4096' "2048")"

  echo
  echo "فرمت controller.quorum.voters باید دقیقاً مشابه سایر نودها باشد."
  local quorum
  quorum="$(prompt_default 'controller.quorum.voters' "1@10.0.0.1:${controller_port},2@10.0.0.2:${controller_port},3@10.0.0.3:${controller_port}")"

  local enable_sasl
  enable_sasl="$(prompt_default 'فعال‌سازی امنیت SASL/SCRAM برای inter-broker؟ (yes/no)' "no")"
  local admin_user="admin"
  local admin_pass=""
  if [[ "$enable_sasl" == "yes" ]]; then
    admin_pass="$(prompt_secret 'رمز عبور کاربر admin (برای inter-broker SCRAM)')"
    [[ -n "$admin_pass" ]] || die "رمز عبور خالی مجاز نیست."
  fi

  write_env_file "$heap_mb"
  generate_server_properties "$node_id" "$roles" "CONTROLLER" "$controller_port" "$broker_port" "$advertised_host" "$quorum" "$KAFKA_DATA_DIR_DEFAULT" "$KAFKA_LOG_DIR_DEFAULT" "$bind_ip" "$enable_sasl" "$admin_user" "$admin_pass"

  save_cluster_id "$cluster_id"
  stop_service
  format_storage "$cluster_id"
  start_enable_service

  local fw
  fw="$(prompt_default 'قانون UFW برای محدود کردن دسترسی به subnet اضافه شود؟ (yes/no)' "no")"
  if [[ "$fw" == "yes" ]]; then
    local subnet
    subnet="$(prompt_default 'subnet مجاز (مثال 10.0.0.0/8 یا 192.168.1.0/24)' "10.0.0.0/8")"
    secure_firewall_optional "$subnet" "$broker_port" "$controller_port"
  fi

  ok "Secondary آماده شد."
}

action_show_config() {
  if [[ -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    info "نمایش خلاصه تنظیمات:"
    grep -E '^(process.roles|node.id|controller.quorum.voters|listeners|advertised.listeners|inter.broker.listener.name|authorizer\.class\.name|super\.users|allow\.everyone\.if\.no\.acl\.found|sasl\.)' "${KAFKA_ETC_DIR}/server.properties" || true
  else
    warn "تنظیمات یافت نشد: ${KAFKA_ETC_DIR}/server.properties"
  fi
}

action_health_check() {
  echo
  info "═══════════════════════════════════════════════════"
  info "        تست سلامت کامل کلاستر Kafka              "
  info "═══════════════════════════════════════════════════"
  
  local health_score=0
  local max_score=10
  
  # 1. چک سرویس
  echo
  info "[1/10] چک سرویس systemd..."
  if systemctl is-active --quiet kafka; then
    ok "✓ سرویس فعال است"
    health_score=$((health_score + 1))
  else
    warn "✗ سرویس فعال نیست"
  fi
  
  # 2. چک پورت broker
  echo
  info "[2/10] چک پورت Broker (9092)..."
  if ss -lnt "( sport = :9092 )" 2>/dev/null | grep -q ":9092"; then
    ok "✓ پورت 9092 باز است"
    health_score=$((health_score + 1))
  else
    warn "✗ پورت 9092 باز نیست"
  fi
  
  # 3. چک پورت controller
  echo
  info "[3/10] چک پورت Controller (9093)..."
  if ss -lnt "( sport = :9093 )" 2>/dev/null | grep -q ":9093"; then
    ok "✓ پورت 9093 باز است"
    health_score=$((health_score + 1))
  else
    warn "✗ پورت 9093 باز نیست"
  fi
  
  # 4. چک پروسه Java
  echo
  info "[4/10] چک پروسه Kafka..."
  if pgrep -f "kafka.Kafka" >/dev/null 2>&1; then
    ok "✓ پروسه Kafka در حال اجرا است"
    health_score=$((health_score + 1))
  else
    warn "✗ پروسه Kafka یافت نشد"
  fi
  
  # 5. چک فضای دیسک
  echo
  info "[5/10] چک فضای دیسک..."
  local disk_usage
  disk_usage=$(df "${KAFKA_DATA_DIR_DEFAULT}" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "100")
  if ((disk_usage < 80)); then
    ok "✓ فضای دیسک کافی است (${disk_usage}% استفاده شده)"
    health_score=$((health_score + 1))
  else
    warn "✗ فضای دیسک کم است (${disk_usage}% استفاده شده)"
  fi
  
  # 6. چک حافظه
  echo
  info "[6/10] چک حافظه سیستم..."
  local mem_avail_mb
  mem_avail_mb=$(free -m | awk 'NR==2 {print $7}' || echo "0")
  if ((mem_avail_mb > 500)); then
    ok "✓ حافظه کافی است (${mem_avail_mb}MB آزاد)"
    health_score=$((health_score + 1))
  else
    warn "✗ حافظه کم است (${mem_avail_mb}MB آزاد)"
  fi
  
  # 7. چک فایل تنظیمات
  echo
  info "[7/10] چک فایل تنظیمات..."
  if [[ -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    ok "✓ فایل تنظیمات موجود است"
    health_score=$((health_score + 1))
  else
    warn "✗ فایل تنظیمات یافت نشد"
  fi
  
  # 8. چک دسترسی‌ها
  echo
  info "[8/10] چک دسترسی‌های فایل..."
  local perm_ok=1
  for dir in "${KAFKA_DATA_DIR_DEFAULT}" "${KAFKA_LOG_DIR_DEFAULT}"; do
    if [[ ! -r "$dir" ]] || [[ ! -w "$dir" ]]; then
      perm_ok=0
      break
    fi
  done
  if ((perm_ok == 1)); then
    ok "✓ دسترسی‌ها صحیح است"
    health_score=$((health_score + 1))
  else
    warn "✗ مشکل در دسترسی‌ها"
  fi
  
  # 9. چک لاگ‌های خطا
  echo
  info "[9/10] چک لاگ‌های خطا در 5 دقیقه اخیر..."
  local error_count
  error_count=$(journalctl -u kafka --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "ERROR" || echo "0")
  if ((error_count == 0)); then
    ok "✓ هیچ خطایی در 5 دقیقه اخیر یافت نشد"
    health_score=$((health_score + 1))
  else
    warn "✗ ${error_count} خطا در لاگ‌های اخیر یافت شد"
  fi
  
  # 10. تست اتصال به localhost
  echo
  info "[10/10] تست اتصال به Broker..."
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/9092" 2>/dev/null; then
    ok "✓ اتصال به broker موفق است"
    health_score=$((health_score + 1))
  else
    warn "✗ نمی‌توانم به broker متصل شوم"
  fi
  
  # نتیجه نهایی
  echo
  info "═══════════════════════════════════════════════════"
  local health_percent=$((health_score * 100 / max_score))
  
  if ((health_percent >= 90)); then
    ok "✓✓✓ سلامت کلاستر: ${health_score}/${max_score} (${health_percent}%) - عالی!"
  elif ((health_percent >= 70)); then
    warn "✓✓ سلامت کلاستر: ${health_score}/${max_score} (${health_percent}%) - خوب"
  elif ((health_percent >= 50)); then
    warn "✓ سلامت کلاستر: ${health_score}/${max_score} (${health_percent}%) - متوسط"
  else
    warn "✗ سلامت کلاستر: ${health_score}/${max_score} (${health_percent}%) - ضعیف"
  fi
  
  echo
  if ((health_score < max_score)); then
    echo "پیشنهاد: برای بررسی جزئیات بیشتر از گزینه 'عیب‌یابی' استفاده کنید."
  fi
}

action_test_produce_consume() {
  echo
  info "═══ تست تولید و مصرف پیام (Producer/Consumer) ═══"
  
  if ! systemctl is-active --quiet kafka; then
    warn "سرویس Kafka اجرا نیست. ابتدا سرویس را start کنید."
    return 1
  fi
  
  local test_topic="test-topic-$(date +%s)"
  
  info "ایجاد topic تست: $test_topic"
  if ! "${KAFKA_SYMLINK}/bin/kafka-topics.sh" --create \
    --bootstrap-server "127.0.0.1:9092" \
    --topic "$test_topic" \
    --partitions 3 \
    --replication-factor 1 2>/dev/null; then
    warn "نتوانستم topic ایجاد کنم. احتمالاً مشکل در اتصال یا ACL"
    return 1
  fi
  
  ok "Topic ایجاد شد"
  
  info "ارسال پیام تست..."
  echo "test-message-$(date -Is)" | "${KAFKA_SYMLINK}/bin/kafka-console-producer.sh" \
    --bootstrap-server "127.0.0.1:9092" \
    --topic "$test_topic" 2>/dev/null || {
    warn "ارسال پیام ناموفق بود"
    return 1
  }
  
  ok "پیام ارسال شد"
  
  info "دریافت پیام..."
  local received
  received=$(timeout 5 "${KAFKA_SYMLINK}/bin/kafka-console-consumer.sh" \
    --bootstrap-server "127.0.0.1:9092" \
    --topic "$test_topic" \
    --from-beginning \
    --max-messages 1 2>/dev/null || echo "")
  
  if [[ -n "$received" ]]; then
    ok "✓ پیام با موفقیت دریافت شد: $received"
  else
    warn "✗ دریافت پیام ناموفق بود"
  fi
  
  info "حذف topic تست..."
  "${KAFKA_SYMLINK}/bin/kafka-topics.sh" --delete \
    --bootstrap-server "127.0.0.1:9092" \
    --topic "$test_topic" 2>/dev/null || true
  
  ok "تست کامل شد"
}

action_service_control() {
  need_root
  
  echo
  echo "مدیریت سرویس Kafka:"
  echo "1) Start"
  echo "2) Stop"
  echo "3) Restart"
  echo "4) Status"
  echo "5) Enable (فعال‌سازی خودکار در بوت)"
  echo "6) Disable (غیرفعال‌سازی خودکار در بوت)"
  echo "0) بازگشت"
  echo
  read -r -p "انتخاب: " svc_choice
  
  case "${svc_choice}" in
    1)
      info "Starting Kafka..."
      systemctl start kafka
      sleep 2
      systemctl status kafka --no-pager || true
      ;;
    2)
      info "Stopping Kafka..."
      systemctl stop kafka
      ok "Kafka متوقف شد"
      ;;
    3)
      info "Restarting Kafka..."
      systemctl restart kafka
      sleep 2
      systemctl status kafka --no-pager || true
      ;;
    4)
      systemctl status kafka --no-pager || true
      ;;
    5)
      systemctl enable kafka
      ok "Kafka در بوت فعال خواهد شد"
      ;;
    6)
      systemctl disable kafka
      ok "Kafka در بوت غیرفعال خواهد شد"
      ;;
    0)
      return 0
      ;;
    *)
      warn "گزینه نامعتبر"
      ;;
  esac
  
  read -r -p "Enter برای ادامه..." _
}

action_backup_config() {
  need_root
  log_init
  
  echo
  info "═══ پشتیبان‌گیری از تنظیمات ═══"
  
  local backup_dir="/root/kafka-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  
  if [[ -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    cp "${KAFKA_ETC_DIR}/server.properties" "$backup_dir/"
    ok "server.properties کپی شد"
  fi
  
  if [[ -f "${KAFKA_ETC_DIR}/cluster.id" ]]; then
    cp "${KAFKA_ETC_DIR}/cluster.id" "$backup_dir/"
    ok "cluster.id کپی شد"
  fi
  
  if [[ -f "$KAFKA_ENV_FILE" ]]; then
    cp "$KAFKA_ENV_FILE" "$backup_dir/"
    ok "kafka env file کپی شد"
  fi
  
  if [[ -f "$SYSTEMD_UNIT" ]]; then
    cp "$SYSTEMD_UNIT" "$backup_dir/"
    ok "systemd unit file کپی شد"
  fi
  
  ok "پشتیبان‌گیری در $backup_dir ذخیره شد"
}

action_reset_node() {
  need_root
  log_init

  local sure
  sure="$(prompt_default 'این کار Kafka را متوقف و دیتا را پاک می‌کند. مطمئنید؟ (yes/no)' "no")"
  if [[ "$sure" != "yes" ]]; then
    ok "لغو شد."
    return 0
  fi

  # پشتیبان خودکار قبل از ریست
  info "ایجاد پشتیبان از تنظیمات قبل از ریست..."
  action_backup_config

  stop_service
  info "حذف دیتا و تنظیمات نود ..."
  run "rm -rf '${KAFKA_DATA_DIR_DEFAULT}'/*"
  run "rm -f '${KAFKA_ETC_DIR}/server.properties' '${KAFKA_ETC_DIR}/cluster.id'"
  ok "ریست انجام شد. فایل‌های backup در /root نگهداری شدند."
}

main_menu() {
  while true; do
    menu_header
    echo "══════════════ نصب و راه‌اندازی ══════════════"
    echo "1) نصب/آماده‌سازی (Java + دانلود Kafka + سرویس)"
    echo "2) راه‌اندازی سرور اولیه (Primary)"
    echo "3) راه‌اندازی سرور کمکی (Secondary)"
    echo
    echo "══════════════ مانیتورینگ و عیب‌یابی ══════════════"
    echo "4) مشاهده وضعیت کلاستر/سرویس"
    echo "5) تست سلامت کامل (Health Check)"
    echo "6) عیب‌یابی جامع با رفع خودکار مشکلات"
    echo "7) تست تولید و مصرف پیام (Producer/Consumer Test)"
    echo
    echo "══════════════ مدیریت ══════════════"
    echo "8) نمایش خلاصه تنظیمات"
    echo "9) پشتیبان‌گیری از تنظیمات"
    echo "10) Start/Stop/Restart سرویس"
    echo "11) ریست نود (پاک‌کردن دیتا/تنظیمات) [خطرناک]"
    echo
    echo "0) خروج"
    echo
    read -r -p "انتخاب شما: " choice
    case "${choice}" in
      1) action_install_prepare ;;
      2) action_setup_primary ;;
      3) action_setup_secondary ;;
      4) cluster_status; read -r -p "Enter برای ادامه..." _ ;;
      5) action_health_check; read -r -p "Enter برای ادامه..." _ ;;
      6) troubleshoot; read -r -p "Enter برای ادامه..." _ ;;
      7) action_test_produce_consume; read -r -p "Enter برای ادامه..." _ ;;
      8) action_show_config; read -r -p "Enter برای ادامه..." _ ;;
      9) action_backup_config; read -r -p "Enter برای ادامه..." _ ;;
      10) action_service_control ;;
      11) action_reset_node; read -r -p "Enter برای ادامه..." _ ;;
      0) exit 0 ;;
      *) warn "گزینه نامعتبر است."; sleep 1 ;;
    esac
  done
}

main() {
  main_menu
}

main "$@"


