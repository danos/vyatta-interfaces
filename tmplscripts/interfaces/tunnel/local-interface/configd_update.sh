#!/opt/vyatta/bin/cliexec

TUN_NAME=$VAR(../@)
if [ $VAR(.) == "local-interface" ]; then
    LOC_INTF=$VAR(@)
    if [ "${LOC_INTF}" != "" ]; then
        INTF_UP=`ip addr show ${LOC_INTF} | grep "UP"`
        if [ "${INTF_UP}" != "" ]; then
            LOC_ADDR=`ip addr show ${LOC_INTF} | grep "inet[^6]" | awk '{print $2}' | awk -F '/' '{print $1}'`
        fi
    fi
else
    if ! /opt/vyatta/sbin/local_ip $VAR(@)
    then
        echo Warning! IP address $VAR(@) does not exist on this system
    fi
    LOC_ADDR=$VAR(@)
fi

if [ "${LOC_ADDR}" != "" ]; then
    case "$VAR(../encapsulation/@)" in
        "gre-bridge")
        ;;
        "gre" | "gre-multipoint" | "ipip" | "sit")
        ;;
        "ipip6" | "ip6ip6")
        if [ -n "$VAR(../parameters/ipv6/encaplimit/@)" ]; then
	    ECL="encaplimit $VAR(../parameters/ipv6/encaplimit/@)"
        fi
        if [ -n "$VAR(../parameters/ipv6/hoplimit/@)" ]; then
	    HL="hoplimit $VAR(../parameters/ipv6/hoplimit/@)"
        fi
        if [ -n "$VAR(../parameters/ipv6/tclass/@)" ]; then
	    TC="tclass $VAR(../parameters/ipv6/tclass/@)"
        fi
        if [ -n "$VAR(../parameters/ipv6/flowlabel/@)" ]; then
	    FL="flowlabel $VAR(../parameters/ipv6/flowlabel/@)"
        fi
        ip -6 tunnel cha ${TUN_NAME} \
	    remote $VAR(../remote-ip/@) mode $VAR(../encapsulation/@) \
	    $HL $ECL $TC $FL
        ;;
    esac
fi
