#!/opt/vyatta/bin/cliexec
type=$(vyatta-tunnel-encap-to-type $VAR(../../../encapsulation/@))
ip link set $VAR(../../../@) type $type ttl $VAR(@)
