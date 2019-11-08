#!/opt/vyatta/bin/cliexec
if [ -n "$VAR(../hoplimit/@)" ]; then
    HL="hoplimit $VAR(../hoplimit/@)"
fi;
if [ -n "$VAR(../tclass/@)" ]; then
    TC="tclass $VAR(../tclass/@)"
fi;
if [ -n "$VAR(../flowlabel/@)" ]; then
    FL="flowlabel $VAR(../flowlabel/@)"
fi;
ip -6 tunnel change $VAR(../../../@) \
    local $VAR(../../../local-ip/@) remote $VAR(../../../remote-ip/@) \
    encaplimit $VAR(@) mode $VAR(../../../encapsulation/@) $HL $TC $FL
