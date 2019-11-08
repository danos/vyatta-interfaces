#!/opt/vyatta/bin/cliexec
type=$(vyatta-tunnel-encap-to-type $VAR(../../../encapsulation/@))

if [ -n "$VAR(../../../path-mtu-discovery-disable/@)" ]; then
    TTL="ttl inherit";
else
    TTL="ttl 255";
fi

ip link set $VAR(../../../@) type $type $TTL
