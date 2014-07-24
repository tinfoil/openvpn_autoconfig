#!/bin/bash
#
# Script to set up OpenVPN for routing all traffic.
# https://github.com/tinfoil/openvpn_autoconfig
#
set -e

if [[ $EUID -ne 0 ]]; then
  echo "You must be a root user" 1>&2
  exit 1
fi

apt-get update -q
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
apt-get install -qy openvpn curl iptables-persistent

cd /etc/openvpn

# Certificate Authority
>ca-key.pem      openssl genrsa 2048
>ca-csr.pem      openssl req -new -key ca-key.pem -subj /CN=OpenVPN-CA/
>ca-cert.pem     openssl x509 -req -in ca-csr.pem -signkey ca-key.pem -days 365
>ca-cert.srl     echo 01

# Server Key & Certificate
>server-key.pem  openssl genrsa 2048
>server-csr.pem  openssl req -new -key server-key.pem -subj /CN=OpenVPN-Server/
>server-cert.pem openssl x509 -req -in server-csr.pem -CA ca-cert.pem -CAkey ca-key.pem -days 365

# Client Key & Certificate
>client-key.pem  openssl genrsa 2048
>client-csr.pem  openssl req -new -key client-key.pem -subj /CN=OpenVPN-Client/
>client-cert.pem openssl x509 -req -in client-csr.pem -CA ca-cert.pem -CAkey ca-key.pem -days 365

# Diffie hellman parameters
>dh.pem     openssl dhparam 2048

chmod 600 *-key.pem

# Set up IP forwarding and NAT for iptables
>>/etc/sysctl.conf echo net.ipv4.ip_forward=1
sysctl -p

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
>/etc/iptables/rules.v4 iptables-save

# Write configuration files for client and server

SERVER_IP=$(curl -s canhazip.com || echo "<insert server IP here>")

>tcp443.conf cat <<EOF
server      10.8.0.0 255.255.255.0
verb        3
duplicate-cn
key         server-key.pem
ca          ca-cert.pem
cert        server-cert.pem
dh          dh.pem
keepalive   10 120
persist-key yes
persist-tun yes
comp-lzo    yes
push        "dhcp-option DNS 8.8.8.8"
push        "dhcp-option DNS 8.8.4.4"

# Normally, the following command is sufficient.
# However, it doesn't assign a gateway when using 
# VMware guest-only networking.
#
# push        "redirect-gateway def1 bypass-dhcp"

push        "redirect-gateway bypass-dhcp"
push        "route-metric 512"
push        "route 0.0.0.0 0.0.0.0"

user        nobody
group       nogroup

proto       tcp
port        443
dev         tun443
status      openvpn-status-443.log
EOF

>client.ovpn cat <<EOF
client
nobind
dev tun
redirect-gateway def1 bypass-dhcp
remote $SERVER_IP 443 tcp
comp-lzo yes

<key>
$(cat client-key.pem)
</key>
<cert>
$(cat client-cert.pem)
</cert>
<ca>
$(cat ca-cert.pem)
</ca>
EOF

service openvpn restart
cat client.ovpn
cd -
