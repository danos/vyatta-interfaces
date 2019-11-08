#!/opt/vyatta/bin/cliexec

case "$VAR(../../../encapsulation/@)" in
    "vxlan" | "vxlan-gpe")
	exit 0;;
esac

# set all parameters back to defaults if deleting this node
ip -6 tunnel change $VAR(../../@) \
    local $VAR(../../local-ip/@) remote $VAR(../../remote-ip/@) \
    hoplimit 64 encaplimit 4 tclass 0x00 flowlabel 0x00000 \
    mode $VAR(../../encapsulation/@)
