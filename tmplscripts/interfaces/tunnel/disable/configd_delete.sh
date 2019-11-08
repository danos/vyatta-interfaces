#!/opt/vyatta/bin/cliexec
ip link set $VAR(../@) up || exit 1
/opt/vyatta/sbin/restore-ipv6-address.pl $VAR(../@)
