#!/opt/vyatta/bin/cliexec
[ -d /sys/class/net/$VAR(../@) ] || exit 0
ip link set $VAR(../@) down
