#!/opt/vyatta/bin/cliexec
if [ -n "$VAR(../parameters/ip/ttl/@)" ] ; then
    echo "path-mtu-discovery-disable and ttl are incompatible"
    exit 1
fi
