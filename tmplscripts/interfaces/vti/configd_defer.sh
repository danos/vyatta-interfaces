#!/opt/vyatta/bin/cliexec
if [ "${COMMIT_ACTION}" == SET ]; then
    `${vyatta_sbindir}/vyatta-vti-config.pl --checkref --intf=$VAR(@)`
    if [ $? -eq 0 ]; then
	echo "Warning: Interface $VAR(@) is not referenced in vpn configuration."
    fi
fi

ifmgrctl register $VAR(@)
