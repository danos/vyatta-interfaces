#!/opt/vyatta/bin/cliexec
if [ "$VAR(../encapsulation/@)" != "gre-bridge" ]; then 
    if [ "$VAR(@)" == "enable" ]; then 
	ip link set $VAR(../@) multicast on allmulticast on
    else
	ip link set $VAR(../@) multicast off allmulticast off
    fi
fi
