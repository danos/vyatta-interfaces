#!/opt/vyatta/bin/cliexec

if [ "$VAR(./encapsulation/@)" == "gre-multipoint" ]; then
    invoke-rc.d opennhrp start;
    ARP="arp on";
fi
if [ "$VAR(./multicast/@)" == "enable" ]; then
    MC="multicast on allmulticast on";
fi
if [ -n "$VAR(./path-mtu-discovery-disable/@)" ]; then
    PMTUDISC="nopmtudisc";
else
    PMTUDISC="pmtudisc";
fi
type=$(vyatta-tunnel-encap-to-type $VAR(./encapsulation/@))
case "$VAR(./encapsulation/@)" in
    "vxlan" | "vxlan-gpe")
        # pmtu control not supported for vxlan
        PMTUDISC=""
        ;;
esac
if [ "$PMTUDISC" != nopmtudisc ] ; then
    if [ -z "$VAR(./parameters/ip/ttl/@)" ]; then
        TTL="ttl 255";
        PMTUDISC="";
    fi
fi
if [ -n "$VAR(./parameters/ip/tos/@)" ]; then
    TOS="tos $VAR(./parameters/ip/tos/@)";
else
    TOS="tos inherit";
fi
# Set parameters not set by vyatta-tunnel-deferred.pl
ip link set $VAR(@) type $type $PMTUDISC $TTL $TOS
vyatta-intf-create $VAR(@) # set interface rdid
ip link set $VAR(@) $MC $ARP up ||
echo "interfaces tunnel $VAR(@): error setting tunnel interface active"
if [ -e /sys/class/net/.spathintf ]; then
    # If we have a gre sysctl then set it to catch locally generated traffic
    if [ -e /proc/sys/net/ipv4/gre/gre_output_if ]; then
	sysctl net.ipv4.gre.gre_output_if=".spathintf" > /dev/null
    fi
    case "$VAR(./encapsulation/@)" in
	gre*)
	    ;;
	*)
	    ip rule add iif $VAR(@) lookup 230
    esac
    ip route add table 230 default dev .spathintf 2> /dev/null
    ref_err=$?
    if [[ $ref_err -ne 0 && $ref_err -ne 2 ]]; then
    exit 1
    fi
fi
