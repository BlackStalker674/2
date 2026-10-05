#!/bin/bash
# BR-SRV, модуль 2, п.1: контроллер домена Samba DC (au-team.irpo)
IFACE=enp7s1   # проверьте имя интерфейса командой ip a

apt-get update && apt-get install -y tzdata task-samba-dc chrony

for s in smb nmb krb5kdc slapd bind; do
  systemctl disable --now $s 2>/dev/null || true
done

rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba /var/cache/samba
mkdir -p /var/lib/samba/sysvol

# Контроллер сам себе DNS
mkdir -p /etc/net/ifaces/$IFACE
printf 'search au-team.irpo\nnameserver 127.0.0.1\n' > /etc/net/ifaces/$IFACE/resolv.conf
systemctl restart network

samba-tool domain provision \
  --realm=AU-TEAM.IRPO \
  --domain=AU-TEAM \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --option="dns forwarder=192.168.100.2" \
  --adminpass='P@ssw0rd'

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable --now samba
systemctl restart samba
sleep 5

# NTP-клиент (сервер - ISP)
cat > /etc/chrony.conf <<'EOF'
server 172.16.2.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
EOF
systemctl enable --now chronyd
systemctl restart chronyd

echo 'P@ssw0rd' | kinit Administrator@AU-TEAM.IRPO

# Группа hq и пять пользователей hquser1..hquser5
samba-tool group add hq
for i in 1 2 3 4 5; do
  samba-tool user add hquser$i 'P@ssw0rd'
  samba-tool user setexpiry hquser$i --noexpiry
  samba-tool group addmembers hq hquser$i
done

# Записи устройств в зоне домена (она теперь обслуживается Samba, иначе hq-srv и др. перестанут резолвиться)
add_a() { samba-tool dns add 127.0.0.1 au-team.irpo "$1" A "$2" -U 'Administrator%P@ssw0rd'; }
add_a hq-rtr  192.168.100.1
add_a hq-srv  192.168.100.2
add_a br-rtr  192.168.0.1
add_a docker  172.16.1.1
add_a web     172.16.2.1

samba-tool domain info 127.0.0.1
samba-tool group listmembers hq
