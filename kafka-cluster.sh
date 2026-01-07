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
  chmod 0600 "$LOG_FILE" 2>/dev/null || true
}

on_error() {
  local exit_code=$?
  local line_no=${1:-"?"}
  warn "اجرا در خط ${line_no} با کد ${exit_code} متوقف شد."
  warn "برای جزئیات بیشتر: $LOG_FILE"
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

apt_install_prereqs() {
  info "نصب پیش‌نیازها (Java, curl, ابزارهای شبکه) ..."
  run "DEBIAN_FRONTEND=noninteractive apt-get update -y"
  run "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless curl ca-certificates tar coreutils gawk sed grep iproute2 lsof util-linux net-tools jq ufw"
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

download_kafka() {
  local kafka_version="$1"
  local scala_version="$2"
  local url="https://downloads.apache.org/kafka/${kafka_version}/kafka_${scala_version}-${kafka_version}.tgz"
  local sha_url="${url}.sha512"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local tgz="${tmp_dir}/kafka.tgz"
  local sha="${tmp_dir}/kafka.tgz.sha512"

  info "دانلود Kafka ${kafka_version} ..."
  run "curl -fsSL --retry 5 --retry-delay 2 -o '${tgz}' '${url}'"
  run "curl -fsSL --retry 5 --retry-delay 2 -o '${sha}' '${sha_url}'"

  info "اعتبارسنجی sha512 ..."
  # فایل sha512 در Apache معمولاً شامل: "<hash>  <filename>"
  # ما فایل tgz را به همان نام مورد انتظار تبدیل می‌کنیم تا sha512sum -c کار کند.
  local expect_name
  expect_name="$(awk '{print $2}' "${sha}" | head -n1)"
  if [[ -z "$expect_name" ]]; then
    die "فرمت فایل sha512 غیرمنتظره است."
  fi
  run "cp '${tgz}' '${tmp_dir}/${expect_name}'"
  run "(cd '${tmp_dir}' && sha512sum -c 'kafka.tgz.sha512')"

  info "استخراج ..."
  local dest="${KAFKA_BASE_DIR}/kafka_${scala_version}-${kafka_version}"
  if [[ -d "$dest" ]]; then
    ok "این نسخه از قبل نصب شده: $dest"
  else
    run "tar -xzf '${tgz}' -C '${KAFKA_BASE_DIR}'"
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
  info "وضعیت سرویس و چند چک پایه ..."
  systemctl --no-pager --full status kafka || true
  echo
  info "پورت‌های در حال گوش دادن (Kafka) ..."
  ss -lntp | grep -E '(:9092|:9093)\s' || true
  echo
  if [[ -x "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" ]]; then
    info "وضعیت quorum (نیازمند دسترسی به controller listener) ..."
    # این دستور روی همان نود، با پورت controller کار می‌کند
    # ممکن است با تنظیمات امنیتی/ACL نیاز به تغییر داشته باشد
    "${KAFKA_SYMLINK}/bin/kafka-metadata-quorum.sh" --bootstrap-server "127.0.0.1:${BROKER_PORT_DEFAULT}" describe --status || true
  else
    warn "kafka-metadata-quorum.sh موجود نیست (احتمالاً نصب ناقص)."
  fi
}

troubleshoot() {
  echo
  info "عیب‌یابی سریع (بدون تغییر) ..."

  echo "- چک دیسک:"
  df -h /var/lib/kafka 2>/dev/null || df -h /var/lib 2>/dev/null || true

  echo
  echo "- چک RAM/CPU:"
  free -h || true
  uptime || true

  echo
  echo "- چک زمان سیستم (برای کلاستر مهم است):"
  timedatectl status 2>/dev/null || true

  echo
  echo "- چک محدودیت فایل‌ها (ulimit):"
  su -s /bin/bash -c 'ulimit -n' "${KAFKA_USER}" 2>/dev/null || true

  echo
  echo "- آخرین لاگ‌های سرویس Kafka:"
  journalctl -u kafka --no-pager -n 200 || true

  echo
  echo "- چک تنظیمات:"
  if [[ -f "${KAFKA_ETC_DIR}/server.properties" ]]; then
    grep -E '^(process.roles|node.id|controller.quorum.voters|listeners|advertised.listeners|inter.broker.listener.name|sasl\.)' "${KAFKA_ETC_DIR}/server.properties" || true
  else
    warn "server.properties پیدا نشد."
  fi

  echo
  echo "- چک فایروال (UFW):"
  ufw status verbose 2>/dev/null || true

  ok "عیب‌یابی سریع تمام شد."
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

  apt_install_prereqs
  require_tools
  ensure_user
  ensure_dirs "$KAFKA_DATA_DIR_DEFAULT" "$KAFKA_LOG_DIR_DEFAULT"

  local kafka_ver scala_ver
  kafka_ver="$(prompt_default 'نسخه Kafka' "$KAFKA_VERSION_DEFAULT")"
  scala_ver="$(prompt_default 'نسخه Scala (برای پکیج Kafka)' "$SCALA_VERSION_DEFAULT")"

  download_kafka "$kafka_ver" "$scala_ver"
  ensure_systemd_unit

  ok "آماده‌سازی کامل شد."
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

action_reset_node() {
  need_root
  log_init

  local sure
  sure="$(prompt_default 'این کار Kafka را متوقف و دیتا را پاک می‌کند. مطمئنید؟ (yes/no)' "no")"
  if [[ "$sure" != "yes" ]]; then
    ok "لغو شد."
    return 0
  fi

  stop_service
  info "حذف دیتا و تنظیمات نود ..."
  run "rm -rf '${KAFKA_DATA_DIR_DEFAULT}'/*"
  run "rm -f '${KAFKA_ETC_DIR}/server.properties' '${KAFKA_ETC_DIR}/cluster.id'"
  ok "ریست انجام شد."
}

main_menu() {
  while true; do
    menu_header
    echo "1) نصب/آماده‌سازی (Java + دانلود Kafka + سرویس)"
    echo "2) راه‌اندازی سرور اولیه (Primary)"
    echo "3) راه‌اندازی سرور کمکی (Secondary)"
    echo "4) مشاهده وضعیت کلاستر/سرویس"
    echo "5) عیب‌یابی (لاگ‌ها و چک‌های سریع)"
    echo "6) نمایش خلاصه تنظیمات"
    echo "7) ریست نود (پاک‌کردن دیتا/تنظیمات) [خطرناک]"
    echo "0) خروج"
    echo
    read -r -p "انتخاب شما: " choice
    case "${choice}" in
      1) action_install_prepare ;;
      2) action_setup_primary ;;
      3) action_setup_secondary ;;
      4) cluster_status; read -r -p "Enter برای ادامه..." _ ;;
      5) troubleshoot; read -r -p "Enter برای ادامه..." _ ;;
      6) action_show_config; read -r -p "Enter برای ادامه..." _ ;;
      7) action_reset_node; read -r -p "Enter برای ادامه..." _ ;;
      0) exit 0 ;;
      *) warn "گزینه نامعتبر است."; sleep 1 ;;
    esac
  done
}

main() {
  main_menu
}

main "$@"


