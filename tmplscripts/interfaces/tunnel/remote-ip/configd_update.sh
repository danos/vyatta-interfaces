#!/opt/vyatta/bin/cliexec
case "$VAR(../encapsulation/@)" in
    "gre-bridge" | "gre" | "ipip" | "sit")
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
    ip -6 tunnel cha $VAR(../@) local $VAR(../local-ip/@) \
	remote $VAR(@) mode $VAR(../encapsulation/@) \
	$HL $ECL $TC $FL
    ;;
esac
