#!/opt/vyatta/bin/cliexec

# if dscp name given, convert it to hex tos field value
tos=$(perl -e "use lib '/opt/vyatta/share/perl5'; use Vyatta::DSCP; \
        my \$dscpval = Vyatta::DSCP::dscp_lookup('$VAR(@)'); \
	if (\$dscpval) { printf \"%x\n\", \$dscpval << 2; } \
	else { printf \"%s\n\", '$VAR(@)' }")
type=$(vyatta-tunnel-encap-to-type $VAR(../../../encapsulation/@))
ip link set $VAR(../../../@) type $type tos $tos
