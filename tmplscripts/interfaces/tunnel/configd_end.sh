#!/opt/vyatta/bin/cliexec
if [ -e /opt/vyatta/sbin/vyatta-update-nhrp.pl ]; then
    /opt/vyatta/sbin/vyatta-update-nhrp.pl --tun "$VAR(@)" --commit_tun;
    /opt/vyatta/sbin/vyatta-update-nhrp.pl --tun "$VAR(@)" --post_commit;
fi
