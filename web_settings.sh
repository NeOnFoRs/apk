set -e

DEVICE=$(hostname)

echo "[*] Настройка имени хоста и временной зоны..."
timedatectl set-timezone Europe/Moscow

if [[ "$DEVICE" == "fw-al" ]]; then
  echo "[FW-AL] Настройка сети..."
  ip addr add 192.168.2.62/26 dev eth0
  ip addr add 1.1.1.2/30 dev eth1
  ip route add default via 1.1.1.1

  echo "[FW-AL] Настройка NTP..."
  sed -i 's/^pool/#pool/' /etc/ntp.conf
  echo "server 127.127.1.0" >> /etc/ntp.conf
  echo "fudge 127.127.1.0 stratum 2" >> /etc/ntp.conf
  systemctl restart ntp

  echo "[FW-AL] Настройка iptables..."
  iptables -P INPUT DROP
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p udp --dport 123 -j ACCEPT
  iptables-save > /etc/iptables/rules.v4

  echo "[FW-AL] Настройка CA..."
  mkdir -p /ca
  openssl genrsa -out /ca/CA.key 4096
  openssl req -x509 -new -nodes -key /ca/CA.key -sha256 -days 3650 \
    -subj "/C=KZ/O=IT Net Kz Inc./CN=IT Net Kz Inc. Root CA" -out /ca/CA.crt

  echo "[FW-AL] Разворачивание Apache для публикации CRL/AIA..."
  mkdir -p /var/www/html/{crl,aia}
  cp /ca/CA.crt /var/www/html/aia/
  touch /var/www/html/crl/ca.crl
  systemctl enable apache2 --now

elif [[ "$DEVICE" == "intra" ]]; then
  echo "[INTRA] Настройка сети..."
  ip addr add 192.168.2.1/26 dev eth0
  ip route add default via 192.168.2.62

  echo "[INTRA] Настройка DNS-сервера bind9..."
  apt install -y bind9
  echo 'zone "itnet.kz" { type master; file "/etc/bind/db.itnet.kz"; };' >> /etc/bind/named.conf.local
  cp /etc/bind/db.local /etc/bind/db.itnet.kz
  sed -i 's/localhost./intra.itnet.kz./g' /etc/bind/db.itnet.kz
  echo "192.168.2.1 intra.itnet.kz" >> /etc/hosts
  systemctl restart bind9

  echo "[INTRA] Настройка LDAP..."
  debconf-set-selections <<< "slapd slapd/no_configuration boolean false"
  dpkg-reconfigure slapd

  echo "[INTRA] Импорт структуры из Приложения B..."
  ldapadd -x -D cn=admin,dc=itnet,dc=kz -w admin <<EOF
dn: ou=Users,dc=itnet,dc=kz
objectClass: organizationalUnit
ou: Users

dn: uid=Abay,ou=Users,dc=itnet,dc=kz
objectClass: inetOrgPerson
sn: Abay
cn: Abay
uid: Abay
userPassword: 123456

# Повторить для Vasy, Bekzat...
EOF

  echo "[INTRA] Настройка RAID..."
  mdadm --create --verbose /dev/md0 --level=5 --raid-devices=3 /dev/sd[b-d]
  mkfs.ext4 /dev/md0
  mkdir /share
  mount /dev/md0 /share
  echo "/dev/md0 /share ext4 defaults 0 0" >> /etc/fstab

  echo "[INTRA] Настройка SAMBA..."
  mkdir -p /share/users/{abay,bekzat,vasy}
  chmod 700 /share/users/*
  apt install -y samba
  cat <<EOT >> /etc/samba/smb.conf
[profiles]
   path = /share/users/%U
   read only = no
   browsable = yes
   guest ok = no
   valid users = %U
EOT
  systemctl restart smbd

  echo "[INTRA] Настройка Cacti и SNMP..."
  systemctl enable snmpd --now
  systemctl enable apache2 --now

  echo "[INTRA] Настройка syslog..."
  mkdir -p /var/log/custom
  echo ':app-name, isequal, "dhcpd" /var/log/custom/dhcp.log' >> /etc/rsyslog.conf
  echo ':app-name, isequal, "postfix" /var/log/custom/mail.log' >> /etc/rsyslog.conf
  echo ':fromhost-ip, isequal, "192.168.2.1" /var/log/custom/dump.log' >> /etc/rsyslog.conf
  systemctl restart rsyslog

  echo "[INTRA] Настройка почты..."
  postconf -e "myhostname = intra.itnet.kz"
  postconf -e "mydomain = itnet.kz"
  postconf -e "myorigin = \$mydomain"
  postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
  systemctl restart postfix dovecot

  echo "[INTRA] Настройка DHCP..."
  apt install -y isc-dhcp-server
  cat <<EOF > /etc/dhcp/dhcpd.conf
subnet 192.168.2.0 netmask 255.255.255.192 {
  range 192.168.2.10 192.168.2.50;
  option routers 192.168.2.62;
  option domain-name-servers 192.168.2.1;
  option domain-name "itnet.kz";
}
EOF
  systemctl enable isc-dhcp-server --now

elif [[ "$DEVICE" == "client" ]]; then
  echo "[CLIENT] Настройка клиента..."
  timedatectl set-timezone Europe/Moscow
  apt install -y gnome-core xrdp thunderbird cifs-utils

  echo "[CLIENT] LDAP и домашняя папка..."
  echo "uri ldaps://intra.itnet.kz/" >> /etc/ldap/ldap.conf
  auth-client-config -t nss -p lac_ldap
  pam-auth-update
  echo "//intra/share/users/%u /home/%u cifs credentials=/etc/samba/cred,iocharset=utf8,sec=ntlm 0 0" >> /etc/fstab

  echo "[CLIENT] Ограничение входа только root/LDAP..."
  echo "account required pam_access.so" >> /etc/pam.d/common-account
  echo "-:ALL EXCEPT root :LOCAL" >> /etc/security/access.conf
  echo "+:ALL:LDAP" >> /etc/security/access.conf

  echo "[CLIENT] Thunderbird: настройка bekzat и abay..."
  echo "[CLIENT] Firefox: установка пользовательского сертификата..."
  certutil -A -n "Bekzat Cert" -t "u,u,u" -i /home/bekzat/bekzat-cert.pem -d sql:/home/bekzat/.mozilla/firefox/*.default-release
fi

echo "[✓] Конфигурация $DEVICE завершена!"
