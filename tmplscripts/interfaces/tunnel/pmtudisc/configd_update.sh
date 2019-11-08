#!/opt/vyatta/bin/cliexec
type=$(vyatta-tunnel-encap-to-type $VAR(../encapsulation/@))
ip link set $VAR(../@) type $type ttl 0;
ip link set $VAR(../@) type $type nopmtudisc;
