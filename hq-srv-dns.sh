#!/bin/bash
# HQ-SRV, модуль 2: чтобы HQ-CLI (DNS = HQ-SRV) нашёл контроллер домена Samba на BR-SRV,
# добавляем в dnsmasq SRV-записи AD. Запускать до ввода HQ-CLI в домен.
DC=br-srv.au-team.irpo
D=au-team.irpo

sed -i '/^# AD-SRV-BEGIN/,/^# AD-SRV-END/d' /etc/dnsmasq.conf
cat >> /etc/dnsmasq.conf <<EOF
# AD-SRV-BEGIN
srv-host=_ldap._tcp.$D,$DC,389
srv-host=_ldap._tcp.dc._msdcs.$D,$DC,389
srv-host=_ldap._tcp.pdc._msdcs.$D,$DC,389
srv-host=_kerberos._tcp.$D,$DC,88
srv-host=_kerberos._udp.$D,$DC,88
srv-host=_kerberos._tcp.dc._msdcs.$D,$DC,88
srv-host=_kpasswd._tcp.$D,$DC,464
srv-host=_kpasswd._udp.$D,$DC,464
srv-host=_gc._tcp.$D,$DC,3268
# AD-SRV-END
EOF

systemctl restart dnsmasq
nslookup -type=SRV _ldap._tcp.$D 127.0.0.1
