#!/opt/vyatta/bin/cliexec

if [ "$VAR(./multicast/@)" == "enable" ]; then
    MC="multicast on allmulticast on";
fi
vyatta-intf-create $VAR(@) # set interface rdid
ip link set $VAR(@) $MC up ||
echo "interfaces tunnel $VAR(@): error setting tunnel interface active"
if [ -e /sys/class/net/.spathintf ]; then
    # If we have a gre sysctl then set it to catch locally generated traffic
    if [ -e /proc/sys/net/ipv4/gre/gre_output_if ]; then
	sysctl net.ipv4.gre.gre_output_if=".spathintf" > /dev/null
    fi
    ip route add table 230 default dev .spathintf 2> /dev/null
    ref_err=$?
    if [[ $ref_err -ne 0 && $ref_err -ne 2 ]]; then
    exit 1
    fi
fi
