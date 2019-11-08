#!/opt/vyatta/bin/cliexec
if [ -d /sys/class/net/$VAR(@) ] ; then
    ip link set $VAR(@) down
    ip link del $VAR(@)
fi
