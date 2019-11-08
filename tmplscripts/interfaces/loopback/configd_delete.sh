#!/opt/vyatta/bin/cliexec
[ $VAR(@) = "lo" ] || ip link delete dev $VAR(@)
