# راهنمای پیشرفته و عیب‌یابی دستی

این سند راهنمای پیشرفته‌تری برای مدیریت دستی و رفع مشکلات خاص کلاستر Kafka ارائه می‌دهد.

## مشکلات رایج و راه‌حل دستی

### 1. خطای "Timed out waiting for a node assignment"

**علت**: نودها نمی‌توانند به یکدیگر متصل شوند یا quorum تشکیل نمی‌شود.

**راه‌حل**:
```bash
# چک اتصال شبکه به سایر نودها
for node in 10.0.0.1 10.0.0.2 10.0.0.3; do
  echo -n "Testing $node:9093: "
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/$node/9093" && echo "OK" || echo "FAILED"
done

# بررسی فایروال
ufw status
iptables -L -n

# چک لاگ برای اطلاعات بیشتر
journalctl -u kafka -n 100 --no-pager | grep -i "connection\|timeout\|refused"
```

### 2. خطای "OutOfMemoryError: Java heap space"

**علت**: حافظه کافی برای JVM تخصیص داده نشده.

**راه‌حل**:
```bash
# ویرایش فایل env
nano /etc/default/kafka

# تغییر به مقدار بالاتر (مثلاً 4GB)
KAFKA_HEAP_OPTS="-Xms4096m -Xmx4096m"

# restart سرویس
systemctl restart kafka
```

### 3. پورت‌ها اشغال هستند

**تشخیص پروسه اشغال‌کننده**:
```bash
# پیدا کردن PID
lsof -i :9092
lsof -i :9093

# یا با ss
ss -lntp | grep -E ':9092|:9093'

# kill پروسه (با احتیاط!)
kill -9 <PID>
```

### 4. دیسک پر شده است

**راه‌حل**:
```bash
# پیدا کردن بزرگترین فایل‌ها
du -sh /var/lib/kafka/* | sort -h

# پاک کردن لاگ‌های قدیمی
find /var/lib/kafka -type f -name "*.log" -mtime +7 -delete

# کاهش retention در تنظیمات
nano /etc/kafka/server.properties
# تغییر:
log.retention.hours=24  # به جای 168
```

### 5. "Could not find or load main class kafka.Kafka"

**علت**: Java یا Kafka به درستی نصب نشده.

**راه‌حل**:
```bash
# چک Java
java -version

# چک symlink Kafka
ls -la /opt/kafka/current

# اگر symlink خراب است
rm /opt/kafka/current
ln -s /opt/kafka/kafka_2.13-3.7.1 /opt/kafka/current

# چک ownership
chown -R kafka:kafka /opt/kafka/
```

### 6. "SASL authentication failed"

**راه‌حل**:
```bash
# چک تنظیمات SASL در server.properties
grep -i sasl /etc/kafka/server.properties

# ساخت کاربر SCRAM (اگر استفاده می‌کنید)
/opt/kafka/current/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --alter --add-config 'SCRAM-SHA-512=[password=secret]' \
  --entity-type users --entity-name admin
```

### 7. نودها از quorum خارج می‌شوند

**علت**: مشکلات شبکه یا زمان همگام نیست.

**راه‌حل**:
```bash
# همگام‌سازی زمان
timedatectl set-ntp true
timedatectl status

# نصب chrony برای NTP بهتر
apt install chrony -y
systemctl enable --now chrony

# چک اختلاف زمان بین نودها
for node in 10.0.0.1 10.0.0.2 10.0.0.3; do
  echo "$node: $(ssh $node date)"
done
```

### 8. خطای "Broker may not be available"

**راه‌حل**:
```bash
# چک advertised.listeners
grep advertised.listeners /etc/kafka/server.properties

# اطمینان از قابل دسترس بودن
# از یک سرور دیگر:
telnet <advertised-host> 9092

# اگر مشکل DNS دارید، از IP استفاده کنید
```

## تنظیمات Performance بهینه

### برای کلاستر Production:

```properties
# در /etc/kafka/server.properties:

# افزایش تعداد network threads
num.network.threads=8

# افزایش تعداد I/O threads
num.io.threads=16

# افزایش buffer sizes
socket.send.buffer.bytes=1048576
socket.receive.buffer.bytes=1048576
socket.request.max.bytes=104857600

# تنظیمات retention
log.retention.hours=168
log.retention.bytes=1073741824
log.segment.bytes=1073741824

# تنظیمات replication
min.insync.replicas=2
default.replication.factor=3

# compression
compression.type=lz4

# برای کاهش latency
num.replica.fetchers=4
replica.lag.time.max.ms=30000
```

### تنظیمات JVM بهینه:

```bash
# در /etc/default/kafka:

KAFKA_HEAP_OPTS="-Xms6g -Xmx6g"

KAFKA_JVM_PERFORMANCE_OPTS="-server \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=20 \
  -XX:InitiatingHeapOccupancyPercent=35 \
  -XX:G1HeapRegionSize=16M \
  -XX:MinMetaspaceFreeRatio=50 \
  -XX:MaxMetaspaceFreeRatio=80 \
  -XX:+ExplicitGCInvokesConcurrent \
  -Djava.awt.headless=true"
```

## مانیتورینگ پیشرفته

### نصب و استفاده از Kafka Manager/UI:

```bash
# نصب docker (اگر ندارید)
apt install docker.io -y

# اجرای Kafka UI
docker run -d -p 8080:8080 \
  -e KAFKA_CLUSTERS_0_NAME=local \
  -e KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS=localhost:9092 \
  provectuslabs/kafka-ui:latest

# دسترسی از مرورگر: http://SERVER_IP:8080
```

### متریک‌های مهم برای چک:

```bash
# استفاده CPU توسط Kafka
top -p $(pgrep -f kafka.Kafka)

# استفاده RAM
ps aux | grep kafka.Kafka

# تعداد file descriptors باز
lsof -p $(pgrep -f kafka.Kafka) | wc -l

# I/O disk
iostat -x 1 5

# Network throughput
iftop -i eth0
```

## Backup و Recovery

### Backup تنظیمات:

```bash
#!/bin/bash
BACKUP_DIR="/backup/kafka-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

cp -r /etc/kafka $BACKUP_DIR/
cp /etc/default/kafka $BACKUP_DIR/
cp /etc/systemd/system/kafka.service $BACKUP_DIR/

tar czf $BACKUP_DIR.tar.gz $BACKUP_DIR
```

### Backup داده (برای disaster recovery):

```bash
# توقف سرویس
systemctl stop kafka

# backup دایرکتوری data
tar czf kafka-data-$(date +%Y%m%d).tar.gz /var/lib/kafka

# راه‌اندازی مجدد
systemctl start kafka
```

### Restore از backup:

```bash
# توقف سرویس
systemctl stop kafka

# پاک کردن داده قدیمی
rm -rf /var/lib/kafka/*

# restore
tar xzf kafka-data-YYYYMMDD.tar.gz -C /

# تنظیم ownership
chown -R kafka:kafka /var/lib/kafka

# راه‌اندازی
systemctl start kafka
```

## امنیت پیشرفته

### فعال‌سازی TLS/SSL:

```bash
# 1. ساخت keystore برای هر broker
keytool -keystore server.keystore.jks -alias localhost \
  -keyalg RSA -validity 365 -genkey

# 2. ساخت CA
openssl req -new -x509 -keyout ca-key -out ca-cert -days 365

# 3. ساخت truststore
keytool -keystore server.truststore.jks -alias CARoot \
  -importcert -file ca-cert

# 4. Sign کردن certificate
keytool -keystore server.keystore.jks -alias localhost \
  -certreq -file cert-file

openssl x509 -req -CA ca-cert -CAkey ca-key -in cert-file \
  -out cert-signed -days 365 -CAcreateserial

# 5. Import certificates
keytool -keystore server.keystore.jks -alias CARoot \
  -importcert -file ca-cert

keytool -keystore server.keystore.jks -alias localhost \
  -importcert -file cert-signed
```

### تنظیمات TLS در server.properties:

```properties
# SSL/TLS Configuration
listeners=SSL://0.0.0.0:9093
ssl.keystore.location=/etc/kafka/ssl/server.keystore.jks
ssl.keystore.password=your-password
ssl.key.password=your-password
ssl.truststore.location=/etc/kafka/ssl/server.truststore.jks
ssl.truststore.password=your-password
ssl.client.auth=required
ssl.enabled.protocols=TLSv1.2,TLSv1.3
ssl.protocol=TLS
```

### فعال‌سازی ACL کامل:

```bash
# اضافه کردن ACL برای topic خاص
/opt/kafka/current/bin/kafka-acls.sh --bootstrap-server localhost:9092 \
  --add --allow-principal User:alice \
  --operation Read --operation Write \
  --topic my-topic

# لیست ACL ها
/opt/kafka/current/bin/kafka-acls.sh --bootstrap-server localhost:9092 \
  --list

# حذف ACL
/opt/kafka/current/bin/kafka-acls.sh --bootstrap-server localhost:9092 \
  --remove --allow-principal User:alice \
  --operation Read --topic my-topic
```

## مهاجرت و Upgrade

### Upgrade Kafka:

```bash
# 1. Backup گرفتن
./kafka-cluster.sh  # گزینه 9

# 2. توقف یک نود (rolling upgrade)
systemctl stop kafka

# 3. دانلود نسخه جدید
cd /opt/kafka
wget https://downloads.apache.org/kafka/3.8.0/kafka_2.13-3.8.0.tgz
tar xzf kafka_2.13-3.8.0.tgz
chown -R kafka:kafka kafka_2.13-3.8.0

# 4. تغییر symlink
ln -sfn /opt/kafka/kafka_2.13-3.8.0 /opt/kafka/current

# 5. راه‌اندازی
systemctl start kafka

# 6. چک سلامت
systemctl status kafka

# 7. تکرار برای نودهای دیگر (یکی یکی)
```

## تست بار (Load Testing)

### استفاده از kafka-producer-perf-test:

```bash
# تست Producer
/opt/kafka/current/bin/kafka-producer-perf-test.sh \
  --topic test-perf \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:9092

# تست Consumer
/opt/kafka/current/bin/kafka-consumer-perf-test.sh \
  --bootstrap-server localhost:9092 \
  --topic test-perf \
  --messages 1000000 \
  --threads 4
```

## لینک‌های مفید

- [مستندات رسمی Kafka](https://kafka.apache.org/documentation/)
- [KRaft Mode](https://kafka.apache.org/documentation/#kraft)
- [Security](https://kafka.apache.org/documentation/#security)
- [Ops & Monitoring](https://kafka.apache.org/documentation/#monitoring)
- [Kafka Improvement Proposals (KIPs)](https://cwiki.apache.org/confluence/display/KAFKA/Kafka+Improvement+Proposals)

## پشتیبانی

اگر مشکلی پیدا کردید که اسکریپت نمی‌تواند خودکار رفع کند:

1. لاگ‌های کامل را بررسی کنید: `journalctl -u kafka -n 500`
2. از گزینه عیب‌یابی جامع استفاده کنید
3. این سند پیشرفته را مطالعه کنید
4. در مستندات رسمی Apache Kafka جستجو کنید

