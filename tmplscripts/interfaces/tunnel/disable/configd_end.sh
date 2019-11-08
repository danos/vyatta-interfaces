#!/opt/vyatta/bin/cliexec
if [ $VAR(../encapsulation/@) == "gre-multipoint" ]; then
    if [ -e "/opt/vyatta/sbin/dmvpn-config.pl" ]; then
        /opt/vyatta/sbin/dmvpn-config.pl \
            --config_file='/etc/dmvpn.conf' \
            --secrets_file='/etc/dmvpn.secrets'
    fi
    if [ -e "/opt/vyatta/sbin/vpn-config.pl" ]; then
        /opt/vyatta/sbin/vpn-config.pl \
            --config_file='/etc/ipsec.conf' \
            --secrets_file='/etc/ipsec.secrets'
    fi
    if [ -e "/opt/vyatta/sbin/vyatta-update-nhrp.pl" ]; then
        /opt/vyatta/sbin/vyatta-update-nhrp.pl --tunnel "$VAR(../@)" --commit_nhrp
    fi
fi
