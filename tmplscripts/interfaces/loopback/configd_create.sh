#!/opt/vyatta/bin/cliexec
[ "$VAR(@)" != "lo" ] && [ ! -d "/sys/class/net/$VAR(@)" ] && ip link add name "$VAR(@)" type dummy
vyatta-intf-create "$VAR(@)"
ip link set "$VAR(@)" up
