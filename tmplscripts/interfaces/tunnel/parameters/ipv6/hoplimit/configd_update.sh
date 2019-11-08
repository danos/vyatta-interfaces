#!/opt/vyatta/bin/cliexec

case "$VAR(../../../encapsulation/@)" in
    "vxlan" | "vxlan-gpe")
    exit 0
    ;;
esac

if [ -n "$VAR(../encaplimit/@)" ]; then
    ECL="encaplimit $VAR(../encaplimit/@)"
fi;
if [ -n "$VAR(../tclass/@)" ]; then
    TC="tclass $VAR(../tclass/@)"
fi;
if [ -n "$VAR(../flowlabel/@)" ]; then
    FL="flowlabel $VAR(../flowlabel/@)"
fi;
ip -6 tunnel change $VAR(../../../@) \
    local $VAR(../../../local-ip/@) remote $VAR(../../../remote-ip/@) \
    mode $VAR(../../../encapsulation/@) \
    hoplimit $VAR(@) $ECL $TC $FL
