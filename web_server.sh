set -e

echo "[+] Обновление списка пакетов..."
apt update

echo "[+] Установка базовых утилит и git..."
apt install -y git curl wget sudo vim net-tools gnupg2 lsb-release ca-certificates software-properties-common unzip gnupg locales tzdata

echo "[+] Установка серверных компонентов..."
apt install -y apache2 ntp slapd ldap-utils samba cifs-utils postfix dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd mailutils thunderbird \
  cacti snmp snmpd syslog-ng certbot iptables-persistent gnome-core xrdp rsyslog-gnutls

echo "[+] Установка RAID и дополнительных инструментов..."
apt install -y mdadm smartmontools

echo "[+] Установка утилит для сертификатов..."
apt install -y openssl

echo "[+] Установка Midnight Commander и других удобств..."
apt install -y mc htop tree

echo "[✓] Установка завершена."