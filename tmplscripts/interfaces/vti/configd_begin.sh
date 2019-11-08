#!/opt/vyatta/bin/cliexec
if [ "${COMMIT_ACTION}" == DELETE ]; then
# check if there is still a reference
    `${vyatta_sbindir}/vyatta-vti-config.pl --checkref --intf=$VAR(@)`
    if [ $? -gt 0 ] ; then
	echo "Interface $VAR(@) is referenced in vpn configuration."
	exit -1
    fi
fi
