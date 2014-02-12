#!/bin/sh
set -e

apt-get update -q
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt-get install -qy openvpn curl iptables-persistent

cd /etc/openvpn
[ -f dh.pem ] || openssl dhparam -out dh.pem 2048

[ -f ca-key.pem ] || openssl genrsa -out ca-key.pem 2048
chmod 600 ca-key.pem
[ -f ca-csr.pem ] || openssl req -new -key ca-key.pem -out ca-csr.pem -subj /CN=OpenVPN-CA/
[ -f ca.pem ] || openssl x509 -req -in ca-csr.pem -out ca.pem -signkey ca-key.pem -days 365
[ -f ca.srl ] || echo 01 > ca.srl

# Server Config
[ -f server-key.pem ] || openssl genrsa -out server-key.pem 2048
chmod 600 server-key.pem
[ -f server-csr.pem ] || openssl req -new -key server-key.pem -out server-csr.pem -subj /CN=OpenVPN/
[ -f cert.pem ] || openssl x509 -req -in server-csr.pem -out server-cert.pem -CA ca.pem -CAkey ca-key.pem -days 365

[ -f udp80.conf ] || cat >udp80.conf <<EOF
server 10.8.0.0 255.255.255.0
verb 3
duplicate-cn
key server-key.pem
ca ca.pem
cert server-cert.pem
dh dh.pem
keepalive 10 120
persist-key
persist-tun
comp-lzo
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

user nobody
group nogroup

proto udp
port 80
dev tun80
status openvpn-status-80.log
EOF

echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

MY_IP_ADDR=$(curl -s http://myip.enix.org/REMOTE_ADDR)
[ "$MY_IP_ADDR" ] || {
    echo "Sorry, I could not figure out my public IP address."
    echo "(I use http://myip.enix.org/REMOTE_ADDR/ for that purpose.)"
    exit 1
}

# Client Config
[ -f client-key.pem ] || openssl genrsa -out client-key.pem 2048
chmod 600 client-key.pem
[ -f client-csr.pem ] || openssl req -new -key client-key.pem -out client-csr.pem -subj /CN=OpenVPN-Client/
[ -f client.pem ] || openssl x509 -req -in client-csr.pem -out client-cert.pem -CA ca.pem -CAkey ca-key.pem -days 365

[ -f client.ovpn ] || cat >client.ovpn <<EOF
client
nobind
dev tun
redirect-gateway def1 bypass-dhcp
remote $MY_IP_ADDR 80 udp
comp-lzo yes

<key>
`cat client-key.pem`
</key>
<cert>
`cat client-cert.pem`
</cert>
<ca>
`cat ca.pem`
</ca>
EOF

service openvpn restart
