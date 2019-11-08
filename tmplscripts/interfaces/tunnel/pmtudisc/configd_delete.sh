#!/opt/vyatta/bin/cliexec

if [ -n "$VAR(../parameters/ip/ttl/@)" ]; then
    TTL="$VAR(../parameters/ip/ttl/@)"
else
    TTL=255
fi
type=$(vyatta-tunnel-encap-to-type $VAR(../encapsulation/@))
ip link set $VAR(../@) type $type ttl $TTL pmtudisc;
