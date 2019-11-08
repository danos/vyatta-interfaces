#!/opt/vyatta/bin/cliexec

case "$VAR(../../../encapsulation/@)" in
    "vxlan" | "vxlan-gpe")
    exit 0
    ;;
esac

if [ -n "$VAR(../hoplimit/@)" ]; then
    HL="hoplimit $VAR(../hoplimit/@)"
fi;
if [ -n "$VAR(../encaplimit/@)" ]; then
    ECL="encaplimit $VAR(../encaplimit/@)"
fi;
if [ -n "$VAR(../flowlabel/@)" ]; then
    FL="flowlabel $VAR(../flowlabel/@)"
fi;
ip -6 tunnel change $VAR(../../../@) \
    local $VAR(../../../local-ip/@) remote $VAR(../../../remote-ip/@) \
    mode $VAR(../../../encapsulation/@) \
    $HL $ECL tclass $VAR(@) $FL
