SUBDIRS = . tests

etcdir = /etc
share_perl5dir = $(datarootdir)/perl5/Vyatta
templatedir = $(datadir)/vyatta-op/templates
opfnsdir = $(datadir)/vyatta-op/functions
tmplscriptdir = $(datadir)/tmplscripts
yangdir = /usr/share/configd/yang
lib_python_interfacesdir = /usr/lib/python3/dist-packages/vyatta/interfaces
lib_python_switchconfigdir = /usr/lib/python3/dist-packages/vyatta
lib_python_dscpdir = /usr/lib/python3/dist-packages/vyatta

bin_SCRIPTS = scripts/ifstats-op-mode
bin_SCRIPTS += scripts/vyatta-show-interfaces.pl
bin_SCRIPTS += scripts/vyatta-vxlan-op
bin_SCRIPTS += scripts/vyatta-switch-op
bin_SCRIPTS += scripts/vyatta-switch-stp-op
bin_SCRIPTS += scripts/yang-getop-interface
sbin_SCRIPTS = scripts/set-rpf-check
sbin_SCRIPTS += scripts/vyatta-interfaces.pl
sbin_SCRIPTS += scripts/vyatta-interfaces-garp
sbin_SCRIPTS += scripts/validate-interfaces.pl
sbin_SCRIPTS += scripts/vyatta-intf-end
sbin_SCRIPTS += scripts/vyatta-intf-create
sbin_SCRIPTS += scripts/vyatta-address
sbin_SCRIPTS += scripts/check-interface-exists.pl
sbin_SCRIPTS += scripts/vyatta-update-unnumbered.pl
sbin_SCRIPTS += scripts/vyatta-unnumbered-update-donor.pl
sbin_SCRIPTS += scripts/interface-address-check
sbin_SCRIPTS += scripts/vyatta-interfaces-tunnel-erspan
sbin_SCRIPTS += scripts/vrf-bind-interface
sbin_SCRIPTS += scripts/vyatta-system-interface
sbin_SCRIPTS += scripts/vyatta-system-intf-end
sbin_SCRIPTS += scripts/vyatta-tunnel-deferred.pl
sbin_SCRIPTS += scripts/vyatta-tunnel-encap-to-type
sbin_SCRIPTS += scripts/vyatta-switch
sbin_SCRIPTS += scripts/vyatta-switch-master
sbin_SCRIPTS += scripts/vyatta-switch-state
sbin_SCRIPTS += scripts/vyatta-switchport
sbin_SCRIPTS += scripts/vyatta-platform-default
sbin_SCRIPTS += scripts/vyatta-update-vifs

share_perl5_DATA = lib/Vyatta/Misc.pm
share_perl5_DATA += lib/Vyatta/Address.pm
share_perl5_DATA += lib/Vyatta/Interface.pm
share_perl5_DATA += lib/Vyatta/VRFInterface.pm
share_perl5_DATA += lib/Vyatta/InterfaceStats.pm
share_perl5_DATA += lib/Vyatta/TypeChecker.pm
share_perl5_DATA += lib/Vyatta/DistributedDataplane.pm
share_perl5_DATA += lib/Vyatta/DSCP.pm
share_perl5_DATA += lib/Vyatta/Rate.pm
share_perl5_DATA += lib/Vyatta/SwitchConfig.pm
share_perl5_DATA += lib/Vyatta/VIFConfig.pm
share_perl5_DATA += lib/Vyatta/Platform.pm
share_perl5_DATA += lib/Vyatta/UnnumberedInterface.pm

lib_python_interfaces_DATA = lib/vyatta/interfaces/interfaces.py
lib_python_switchconfig_DATA = lib/vyatta/switchconfig.py
lib_python_dscp_DATA = lib/vyatta/DSCP.py

sysconf_DATA = sysconf/netdevice
sysconf_DATA += sysconf/system
sysconf_DATA += sysconf/hardware-features

cpiop = find  . ! -regex '\(.*~\|.*\.bak\|.*\.swp\|.*\#.*\#\)' -print0 | \
 cpio -0pd

install-exec-hook:
	mkdir -p $(DESTDIR)$(tmplscriptdir)
	cd tmplscripts && $(cpiop) $(DESTDIR)$(tmplscriptdir)
	mkdir -p $(DESTDIR)$(templatedir)
	cd templates && $(cpiop) $(DESTDIR)$(templatedir)
	mkdir -p $(DESTDIR)$(yangdir)
	cd yang && $(cpiop) $(DESTDIR)$(yangdir)
	mkdir -p $(DESTDIR)$(opfnsdir)/tech-support.d
	cd scripts/tech-support && $(cpiop) $(DESTDIR)$(opfnsdir)/tech-support.d
	mkdir -p $(DESTDIR)$(opfnsdir)/tech-support-brief.d
	cd scripts/tech-support-brief && $(cpiop) $(DESTDIR)$(opfnsdir)/tech-support-brief.d
