#!/opt/vyatta/bin/cliexec
if [ "$VAR(@)" == "enable" ]; then
    ip link set $VAR(../@) multicast on
else
    ip link set $VAR(../@) multicast off
fi
