#!/usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2007-2017, Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";

use File::Remove qw(remove);
use File::Slurp qw(read_dir read_file);
use Getopt::Long;
use JSON qw( decode_json );
use NetAddr::IP::Lite;
use NetAddr::IP;

use Vyatta::Address;
use Vyatta::Config;
use Vyatta::Interface qw($VDR_SPATH_OVERHEAD validate_dev_mtu);
use Vyatta::Misc qw(getInterfaces getIP get_sysfs_value is_address_enabled
  is_ip_v4_or_v6 is_addr_loopback is_addr_multicast valid_ip_prefix
  valid_ipv6_prefix);
use Vyatta::RestoreIPv6Addr;

my $ETHTOOL = '/sbin/ethtool';

my ( $dev, %skip_interface, $vif_name );
my $DEFAULT_MTU = 1500;

# This is a "modulino" (http://www.drdobbs.com/scripts-as-modules/184416165)
exit __PACKAGE__->main()
  unless caller();

sub main {
    my ( $mac,        $mac_update,    $mac_delete );
    my ( $check_name, $show_names,    $show_filter, $next_nodes, $warn_name );
    my ( $check_up,   $allowed_speed, $delete_description );
    my ( $create_vif, $check_vif,     $check_configured );
    my ( $delete_vif,  $update_vif,   $set_mtu,      $del_mtu );
    my ( $update_vlan, $update_ivlan, $delete_ivlan, $update_pvid );
    my ( @speed_duplex, @addr_commit, @check_speed );
    my ($check_donor);
    my ( $unnumbered_type, $unnumbered_intf );
    my ($check_vifs);
    my ($delete_vlan);
    my ( $check_dev, $create_dev, $delete_dev );
    my ($validate_dp_interface);
    my ( $validate_interface, @addrs, $conf_line );
    my ( $dev_mtu, $check_mtu, $action, $check_dev_mtu );
    my ( $subports, $reservedintf );

    GetOptions(
        "valid-addr-commit=s{,}" => \@addr_commit,
        "dev=s"                  => \$dev,
        "valid-mac=s"            => \$mac,
        "set-mac=s"              => \$mac_update,
        "del-mac"                => \$mac_delete,
        "check=s"                => \$check_name,
        "show=s"                 => \$show_names,
        "skip=s"                 => sub { $skip_interface{ $_[1] } = 1 },
        "filter-out=s"           => \$show_filter,
        "includes=s"             => \$next_nodes,
        "vif=s"                  => \$vif_name,
        "warn"                   => \$warn_name,
        "isup"                   => \$check_up,
        "speed-duplex=s{2}"      => \@speed_duplex,
        "check-speed=s{2}"       => \@check_speed,
        "allowed-speed"          => \$allowed_speed,
        "check-vif=s"            => \$check_vif,
        "create-vif=s"           => \$create_vif,
        "configured"             => \$check_configured,
        "valid-donor-commit=s"   => \$check_donor,
        "delete-vif=s"           => \$delete_vif,
        "update-vif=s"           => \$update_vif,
        "set-mtu=s"              => \$set_mtu,
        "del-mtu=s"              => \$del_mtu,
        "update-vlan"            => \$update_vlan,
        "update-ivlan"           => \$update_ivlan,
        "del-ivlan"              => \$delete_ivlan,
        "check_unnumbered=s"     => \$unnumbered_type,
        "unnumbered_intf=s"      => \$unnumbered_intf,
        "update-vlan-proto=s"    => \$update_pvid,
        "check-vifs"             => \$check_vifs,
        "delete-vlan"            => \$delete_vlan,
        "delete-description"     => \$delete_description,
        "check-dev=s"            => \$check_dev,
        "create-dev=s"           => \$create_dev,
        "delete-dev=s"           => \$delete_dev,
        "validate-interface"     => \$validate_interface,
        "addrs:s{,}"             => \@addrs,
        "set-dev-mtu=s"          => \$dev_mtu,
        "validate-dev-mtu=s"     => \$check_dev_mtu,
        "action=s"               => \$action,
        "conf-line"              => \$conf_line,
        "breakout=s"             => \$subports,
        "breakout-reserved=s"    => \$reservedintf,

        # Actions below this point are likely no longer used following
        # work to improve validation and commit times.  However, as it's
        # hard to be 100% sure all users have been removed, code is being
        # left for now.
        "validate-dp-interface" => \$validate_dp_interface,

    ) or usage();

    is_valid_addr_commit( $dev, @addr_commit ) if (@addr_commit);
    is_valid_mac( $mac, $dev ) if ($mac);
    update_mac( $mac_update, $dev ) if ($mac_update);
    update_mac( undef,       $dev ) if ($mac_delete);
    is_valid_vif( $check_vif, $dev ) if ($check_vif);
    add_vif( $create_vif, $dev ) if ($create_vif);
    del_vif( $delete_vif, $dev ) if ($delete_vif);
    update_vlan( $update_vif, $dev ) if ($update_vlan);
    update_ivlan( $update_vif, $dev ) if ($update_ivlan);
    delete_ivlan( $update_vif, $dev ) if ($delete_ivlan);
    delete_vlan( $update_vif, $dev ) if ($delete_vlan);
    update_vif_mtu( $dev, $update_vif, $set_mtu ) if ($set_mtu);
    del_vif_mtu( $dev, $update_vif, $del_mtu ) if ($del_mtu);
    is_valid_name( $check_name, $dev ) if ($check_name);
    exists_name($dev) if ($warn_name);
    show_interfaces( $show_names, $show_filter, $next_nodes ) if ($show_names);
    print_conf_line($dev) if ($conf_line);
    is_up($dev)           if ($check_up);
    set_speed_duplex( $dev, @speed_duplex ) if (@speed_duplex);
    check_speed_duplex( $dev, @check_speed ) if (@check_speed);
    allowed_speed($dev) if ($allowed_speed);
    is_configured($dev) if ($check_configured);
    is_donor( $dev, $check_donor ) if ($check_donor);
    is_check_unnumbered( $unnumbered_type, $unnumbered_intf )
      if ($unnumbered_type);
    check_vifs($dev)           if ($check_vifs);
    clear_ifalias($dev)        if ($delete_description);
    check_device($check_dev)   if defined($check_dev);
    create_device($create_dev) if defined($create_dev);
    delete_device($delete_dev) if defined($delete_dev);
    validate_device( $dev, @addrs ) if ($validate_interface);
    validate_dp_device( $dev, @addrs ) if ($validate_dp_interface);
    update_dev_mtu( $dev, $dev_mtu, $action ) if ($dev_mtu);
    validate_dev_mtu( $dev, $check_dev_mtu, $action ) if ($check_dev_mtu);
    process_breakout( $action, $subports, $dev, $reservedintf )
      if defined($subports);

    exit 0;
}

sub usage {
    print <<EOF;
Usage: $0 --dev=<interface> --check=<type>
       $0 --dev=<interface> --warn
       $0 --dev=<interface> --valid-mac=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --valid-addr-commit={addr1 addr2 ...}
       $0 --dev=<interface> --valid-donor-commit=ip|ipv6
       $0 --dev=<interface> --speed-duplex=speed,duplex
       $0 --dev=<interface> --check-speed=speed,duplex
       $0 --dev=<interface> --allowed-speed
       $0 --dev=<interface> --isup
       $0 --dev=<interface> --set-mac=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --check-vif=NN
       $0 --dev=<interface> --create-vif=NN
       $0 --dev=<interface> --configured
       $0 --dev=<interface> --delete-description
       $0 --dev=<interface> --conf-line
       $0 --dev=<interface> --breakout=<n> [--breakout-reserved=<interface>]
       $0 --show=<type>[,<type>[...]] --filter-out=<regexp> --includes=<nodes>
EOF
    exit 1;
}

sub warn_failure {
    my $cmd = shift;
    system($cmd) == 0 or warn "'$cmd' failed\n";
}

sub is_ip_configured {
    my ( $intf, $ip ) = @_;
    my $found = grep { $_ eq $ip } Vyatta::Misc::getIP($intf);
    return ( $found > 0 );
}

sub is_up {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);

    die "Unknown interface type for $name" unless $intf;

    exit 0 if ( $intf->up() );
    exit 1;
}

sub get_interface_info {
    my $ifname = shift;

    # VDR doesn't have a local controller to ask about the system interfaces
    # used for management connectivity.
    return unless eval 'use Vyatta::Dataplane; 1';

    my $intf = new Vyatta::Interface($ifname);

    return unless defined($intf);
    return unless defined( $intf->dpid() );

    ( my $dp_ids, my $dp_conns ) = Vyatta::Dataplane::setup_fabric_conns();

    my $response = vplane_exec_cmd( "ifconfig $ifname", $dp_ids, $dp_conns, 1 );

    for my $dp_id ( @{$dp_ids} ) {
        next unless defined( $response->[$dp_id] );

        my $decoded = decode_json( $response->[$dp_id] );
        my $ifinfo  = $decoded->{interfaces}->[0];
        next unless defined($ifinfo);

        if ( $ifinfo->{name} eq $ifname ) {
            Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
            return $ifinfo;
        }
    }

    Vyatta::Dataplane::close_fabric_conns( $dp_ids, $dp_conns );
    return;
}

sub update_mac {
    my ( $mac, $name ) = @_;
    my $intf = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    my $ifinfo = get_interface_info($name);
    if (    defined($ifinfo)
        and defined( $ifinfo->{dev}->{mac_addr_settable} )
        and $ifinfo->{dev}->{mac_addr_settable} eq JSON::false )
    {
        printf "WARNING: Not setting MAC address for $name"
          . " -- Unsupported operation\n";
        exit 0;
    }

    # for deletion revert to the permanent MAC address
    # ethtool output is of the form 'Permanent address: <address>'
    $mac = ( split( ' ', qx($ETHTOOL -P $name) ) )[2] unless defined($mac);

    # maybe nothing needs to change
    my $oldmac = $intf->hw_address();
    exit 0 if ( lc($oldmac) eq lc($mac) );

    # try the direct approach
    if ( system("ip link set $name address $mac") ) {
        if ( $intf->up() ) {

            # some hardware can not change MAC address if up
            system "ip link set $name down"
              and die "Could not set $name down\n";
            system "ip link set $name address $mac"
              and die "Could not set $name address\n";
            system "ip link set $name up"
              and die "Could not set $name up\n";
        } else {
            die "Could not set mac address for $name\n";
        }
    }

    # Update IPv6 global EUI64 addresses after MAC address change
    if ( -d "/proc/sys/net/ipv6/conf/$name" ) {
        Vyatta::RestoreIPv6Addr::restore_address(
            {
                interfaces    => [$name],
                force_restore => 1,
                old_mac       => $oldmac
            }
        );
    }

    exit 0;
}

sub is_vrrp_mac {
    my @octets = @_;
    return 1
      if ( hex( $octets[0] ) == 0
        && hex( $octets[1] ) == 0
        && hex( $octets[2] ) == 94
        && hex( $octets[3] ) == 0
        && hex( $octets[4] ) == 1 );
    return 0;
}

sub is_valid_mac {
    my ( $mac, $intf ) = @_;
    my @octets = split /:/, $mac;

    ( $#octets == 5 ) or die "Error: wrong number of octets: $#octets\n";

    ( ( hex( $octets[0] ) & 1 ) == 0 )
      or die "Error: $mac is a multicast address\n";

    is_vrrp_mac(@octets) and die "Error: $mac is a vrrp mac address\n";

    my $sum = 0;
    $sum += hex($_) foreach @octets;
    ( $sum != 0 ) or die "Error: zero is not a valid address\n";

    exit 0;
}

# Validate the set of address values configured on an interface at commit
# Check that full set of address address values are consistent.
#  1. Interface may not be part of bridge or bonding group
#  2. Can not have both DHCP and a static IPv4 address.
sub is_valid_addr_commit {
    my ( $ifname, @addrs ) = @_;
    my $intf = new Vyatta::Interface($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";

    my $config = new Vyatta::Config( $intf->path() );

    my $bridge = $config->returnValue("bridge-group bridge");
    die "Can't configure address on interface that is port of bridge.\n"
      if ( defined($bridge) );

    my $bond = $config->returnValue("bond-group");
    die
"Can't configure address on interface that is slaved to bonding interface.\n"
      if ( defined($bond) );

    my ( $dhcp, $dhcpv6, $static_v4, $static_v6 );
    foreach my $addr (@addrs) {
        if ( $addr eq 'dhcpv6' ) {
            $dhcpv6 = 1;
            next;
        }
        if ( $addr eq 'dhcp' ) {
            $dhcp = 1;
            next;
        }

        my $ip = new NetAddr::IP $addr;

        # Allow 127.0.0.1 loopback address only on 'lo' interfaces.
        die "$addr reserved for system use\n"
          unless ( $intf->name() eq 'lo' || not is_addr_loopback($ip) );

        # Check if the address is a multicast address.
        die "$addr reserved for multicast use\n"
          if ( is_addr_multicast($ip) );

        $static_v4 = 1
          if ( Vyatta::Address::is_ipv4($addr) );

        if ( Vyatta::Misc::valid_ipv6_prefix($addr) ) {
            $static_v6 = 1;
        }
    }

    die "Can't configure static IPv4 address and DHCP on the same interface.\n"
      if ( $static_v4 && $dhcp );

    die
      "Can't configure static IPv6 address and DHCPv6 on the same interface.\n"
      if ( $static_v6 && $dhcpv6 );

    exit 0;
}

sub is_valid_name {
    my ( $type, $name ) = @_;
    die "Missing --dev argument\n" unless $name;

    my $intf = new Vyatta::Interface($name);
    die "$name does not match any known interface name type\n"
      unless $intf;

    my $vif = $intf->vif();
    die "$name is the name of VIF interface\n",
      "Need to use \"interface ", $intf->physicalDevice(), " vif $vif\"\n"
      if $vif;

    die "$name is a ", $intf->type(), " interface not an $type interface\n"
      if ( $type ne 'all' and $intf->type() ne $type );

    die "$type interface $name does not exist on system\n"
      unless grep { $name eq $_ } getInterfaces();

    exit 0;
}

sub check_vifs {
    my $dev   = shift;
    my $vlans = {};

    die "Missing --dev argument\n" unless $dev;

    my $intf = new Vyatta::Interface($dev);
    die "$dev does not match any known interface"
      unless $intf;

    my $config = new Vyatta::Config( $intf->path() );

    foreach my $id ( $config->listNodes("vif") ) {
        my $inner_vlan = $config->returnValue("vif $id inner-vlan");
        my $vlan       = $config->returnValue("vif $id vlan");

        die "Please configure a vlan-id for $dev.$id\n"
          if ( defined($inner_vlan) && !defined($vlan) );

        # The vlan range is 1..4094. We are assigning vid to vlan
        # when the vlan is not specified. Ask user to enter vlan
        # when the vid > 4094.
        die "Please configure a vlan-id for $dev.$id\n"
          if ( $id > 4094 && !defined($vlan) );

        $inner_vlan = 0   unless ( defined($inner_vlan) );
        $vlan       = $id unless ( defined($vlan) );

        my $old_inner_vlan = $vlans->{$vlan};
        $vlans->{$vlan} = $inner_vlan;

        next unless ( defined($old_inner_vlan) );
        die "vlan $vlan already used by another vif\n"
          unless ( $inner_vlan && $old_inner_vlan );
    }
    return 0;
}

sub is_valid_vif {
    my ( $vif, $dev ) = @_;
    die "Missing --dev argument\n" unless $dev;

    my $name = "$dev.$vif";
    my $intf = new Vyatta::Interface($dev);
    die "$dev does not match any known interfacen"
      unless $intf;

    my $config        = new Vyatta::Config( $intf->path() );
    my $vlan          = $config->returnValue("vif $vif vlan");
    my $ntag          = defined($vlan) ? $vlan : $vif;
    my $inner_vlan    = $config->returnValue("vif $vif inner-vlan");
    my $new_inner_tag = defined($inner_vlan) ? $inner_vlan : 0;

    foreach my $id ( $config->listNodes("vif") ) {
        next if ( $id eq $vif );

        $vlan = $config->returnValue("vif $id vlan");
        my $otag = defined($vlan) ? $vlan : $id;
        $inner_vlan = $config->returnValue("vif $id inner-vlan");
        my $old_inner_tag = defined($inner_vlan) ? $inner_vlan : 0;

        my $error =
          $old_inner_tag == 0
          ? "Vlan tag $otag already in use by $dev.$id\n"
          : "Vlan tag $otag.$old_inner_tag already in use by $dev.$id\n";

        # do not allow single vlan vif having the same vlan id as the
        # outer-vid of a q-in-q i/f
        die $error
          if ( ( $otag eq $ntag && $old_inner_tag eq $new_inner_tag )
            || ( $otag eq $ntag && $old_inner_tag == 0 ) );
    }
    exit 0;
}

sub add_vif {
    return unless eval 'use Vyatta::VIFConfig; 1';

    Vyatta::VIFConfig::add_vif(@_);
    exit 0;
}

sub update_vlan {
    return unless eval 'use Vyatta::VIFConfig; 1';

    Vyatta::VIFConfig::add_vif(@_);
    exit 0;
}

sub delete_vlan {
    my ( $vif, $dev ) = @_;
    die "Missing --dev argument\n" unless $dev;

    my $parent = new Vyatta::Interface($dev);
    die "$dev is not a known interface type"
      unless defined($parent);
    my $config = new Vyatta::Config( $parent->path() );
    my $vlan   = $config->returnValue("vif $vif vlan");

    exit 0 if ( defined($vlan) );
    exit 0 unless ( $config->exists("vif $vif") );

    update_vlan( $vif, $dev );

    exit 0;
}

sub update_ivlan {
    return unless eval 'use Vyatta::VIFConfig; 1';

    Vyatta::VIFConfig::update_ivlan(@_);
    exit 0;
}

sub delete_ivlan {
    my ( $vif, $dev ) = @_;
    die "Missing --dev argument\n" unless $dev;

    my $parent = new Vyatta::Interface($dev);
    die "$dev is not a known interface type"
      unless defined($parent);
    my $config     = new Vyatta::Config( $parent->path() );
    my $inner_vlan = $config->returnValue("vif $vif inner-vlan");

    exit 0 if ( defined($inner_vlan) );

    exit 0 unless ( $config->exists("vif $vif") );

    update_ivlan( $vif, $dev );

    exit 0;
}

sub del_vif {
    return unless eval 'use Vyatta::VIFConfig; 1';

    Vyatta::VIFConfig::del_vif(@_);
    exit 0;
}

sub get_mtu {
    my ($name) = @_;

    return @{ decode_json(`ip -j link show $name`) }[0]->{mtu};
}

#
# Update MTU on swN.
#
sub update_switch_parent_mtu {
    my ( $name, $add, $mtu, $phy_mtu ) = @_;
    my $max_mtu = $DEFAULT_MTU;

    return if index( $name, "sw" ) == -1;

    if ($add) {
        return if $phy_mtu >= $mtu;

        warn_failure("ip link set $name mtu $mtu");
        return;
    }

    #
    # When deleting a VIF MTU, find the highest MTU
    # of the remaining VIFs under the same switch intf.
    #
    opendir( DIR, "/sys/class/net/" );
    my @files = grep( /$name\./, readdir(DIR) );
    closedir(DIR);

    foreach my $file (@files) {
        my $vlan_mtu = read_file("/sys/class/net/$file/mtu");
        $max_mtu = $vlan_mtu if ( $vlan_mtu > $max_mtu );
    }

    warn_failure("ip link set $name mtu $max_mtu");
}

sub update_vif_mtu {
    my ( $name, $vif, $mtu ) = @_;
    my $vifname = "$name.$vif";
    my $intf    = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    my $config     = new Vyatta::Config( $intf->path() );
    my $vlan       = $config->returnValue("vif $vif vlan");
    my $inner_vlan = $config->returnValue("vif $vif inner-vlan");
    my $phy_mtu    = $config->returnValue("mtu");

    # for vlan-aware bridges, switches, the master mtu is
    # handled automatically -- no configuration
    $phy_mtu = get_mtu($name) if !defined($phy_mtu);

    update_switch_parent_mtu( $name, 1, $mtu, $phy_mtu );

    # set underlying outer vlan i/f mtu
    if ( defined($inner_vlan) ) {
        my $max_mtu = $mtu;
        my $vif_mtu;
        my $outer_vname = "$dev.0$vlan";

        foreach my $id ( $config->listNodes("vif") ) {
            next if ( $id eq $vif );
            next if !( -d "/sys/class/net/$dev.$id" );

            $vif_mtu = get_sysfs_value( "$dev.$id", "mtu" );
            $max_mtu = $vif_mtu if ( $max_mtu < $vif_mtu );
        }

        warn_failure("ip link set $outer_vname mtu $max_mtu")
          if ( ( -e "/sys/class/net/$outer_vname/mtu" )
            && get_sysfs_value( "$outer_vname", "mtu" ) != $max_mtu );
    }

    warn_failure("ip link set $vifname mtu $mtu")
      if ( -d "/sys/class/net/$vifname" );

    exit 0;
}

sub del_vif_mtu {
    my ( $name, $vif, $mtu ) = @_;
    my $vifname = "$name.$vif";
    my $intf    = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    my $config     = new Vyatta::Config( $intf->path() );
    my $vlan       = $config->returnOrigValue("vif $vif vlan");
    my $inner_vlan = $config->returnOrigValue("vif $vif inner-vlan");
    my $phy_mtu    = $config->returnOrigValue("mtu");

    # for vlan-aware bridges, switches, the master mtu
    # is handled automatically -- no configuration
    $phy_mtu = get_mtu($name) if !defined($phy_mtu);

    # make sure vif's mtu is not greater than the phy mtu
    $mtu = $phy_mtu if ( $mtu > $phy_mtu );

    # set underlying outer vlan i/f mtu
    if ( defined($inner_vlan) ) {
        my $max_mtu = $mtu;
        my $vif_mtu;
        my $outer_vname = "$dev.0$vlan";

        foreach my $id ( $config->listNodes("vif") ) {
            next if ( $id eq $vif );
            next if !( -d "/sys/class/net/$dev.$id" );

            $vif_mtu = get_sysfs_value( "$dev.$id", "mtu" );
            $max_mtu = $vif_mtu if ( $max_mtu < $vif_mtu );
        }

        warn_failure("ip link set $outer_vname mtu $max_mtu")
          if ( ( -e "/sys/class/net/$outer_vname/mtu" )
            && get_sysfs_value( "$outer_vname", "mtu" ) != $max_mtu );
    }

    warn_failure("ip link set $vifname mtu $mtu")
      if ( -d "/sys/class/net/$vifname" );

    update_switch_parent_mtu( $name, 0, $mtu, $phy_mtu );

    exit 0;
}

sub update_pvid {
    my ( $dev, $pvid ) = @_;
    die "Missing --dev argument\n" unless $dev;

    my $intf = new Vyatta::Interface($dev);
    die "$dev does not match any known interfacen"
      unless $intf;

    my $config   = new Vyatta::Config( $intf->path() );
    my $old_pvid = $config->returnOrigValue("vlan-protocol");

    exit 0 if ( !defined($old_pvid) );

    my %vlans;
    foreach my $id ( $config->listNodes("vif") ) {
        my $vlan = $config->returnValue("vif $id vlan");
        $vlan = $id if !defined($vlan);
        my $inner_vlan = $config->returnValue("vif $id inner-vlan");
        my $vif_name   = "$dev.$id";

        next if ( defined( $vlans{$vlan} ) );

        $vlans{$vlan} = 1;
        $vif_name = "$dev.0$vlan" if ( defined($inner_vlan) );

        warn_failure("ip link set $vif_name type vlan proto $pvid")
          if ( -d "/sys/class/net/$vif_name" );
    }
    exit 0;
}

sub exists_name {
    my $name = shift;
    die "Missing --dev argument\n" unless $name;

    warn "interface $name does not exist on system\n"
      unless grep { $name eq $_ } getInterfaces();
    exit 0;
}

sub is_one_of {
    my ( $needle, $haystack ) = @_;

    my @haystack = split /,/, $haystack;
    foreach my $tmp (@haystack) {
        return 1
          if ( $needle eq $tmp );
    }
    return;
}

# generate one line with all known interfaces (for allowed)
sub show_interfaces {
    my ( $types, $filter, $next_nodes ) = @_;
    my @interfaces = getInterfaces();
    my @match;

    return unless eval 'use Vyatta::SwitchConfig qw(is_hw_interface); 1';

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf;    # skip unknown types

        next
          if !is_one_of( 'switch', $types )
          and $intf->type() eq 'switch'
          and !defined $intf->vif();
        next if $skip_interface{$name};
        next if ( defined($filter) && $name =~ /$filter/ );
        next if ( $types eq 'all_but_hw' && is_hw_interface($name) );
        next unless ( $types =~ '^all' || is_one_of( $intf->type(), $types ) );

        if ( defined($next_nodes) ) {
            my $conf_line = get_conf_line($name);
            my $cfg       = new Vyatta::Config();

            next unless $cfg->existsOrig("$conf_line $next_nodes");
        }

        if ( $intf->vrid() ) {
            push @match, $name;    # add all vrrp interfaces
        } elsif ($vif_name) {
            next unless $intf->vif();
            push @match, $intf->vif()
              if ( $vif_name eq $intf->physicalDevice() );
        } else {
            push @match, $name;
        }
    }

    print join( ' ', sort(@match) ), "\n";
}

# print out the configuration line that would be used in configuring
# this interface
sub print_conf_line {
    my $dev = shift;
    die "Missing --dev argument\n" unless $dev;

    printf "%s\n", get_conf_line($dev);
    return 0;
}

# return the configuration line that would be used in configuring an interface
sub get_conf_line {
    my $dev = shift;

    my $intf = new Vyatta::Interface($dev);
    die "Type of $dev is not known\n" unless defined($intf);

    my $type     = $intf->type();
    my $phys     = $intf->physicalDevice();
    my $vif      = $intf->vif();
    my $vif_info = $vif ? " vif $vif" : "";
    return "interfaces $type $phys$vif_info";
}

# Determine current values for autoneg, speed, duplex
sub get_ethtool {
    my $dev = shift;

    open( my $ethtool, '-|', "$ETHTOOL $dev 2>&1" )
      or die "ethtool failed: $!\n";

    # ethtool produces:
    #
    # Settings for eth1:
    # Supported ports: [ TP ]
    # ...
    # Speed: 1000Mb/s
    # Duplex: Full
    # ...
    # Auto-negotiation: on
    my ( $rate, $duplex );
    my $autoneg = 0;
    while (<$ethtool>) {
        chomp;
        return if (/^Cannot get device settings/);

        if (/^\s+Speed: (\d+)Mb/) {
            $rate = $1;
        } elsif (/^\s+Duplex:\s(.*)$/) {
            $duplex = lc $1;
        } elsif (/^\s+Auto-negotiation: on/) {
            $autoneg = 1;
        }
    }
    close $ethtool;
    return ( $autoneg, $rate, $duplex );
}

sub set_speed_duplex {
    my ( $intf, $nspeed, $nduplex ) = @_;
    die "Missing --dev argument\n" unless $intf;

    # read old values to avoid meaningless speed changes
    my ( $autoneg, $ospeed, $oduplex ) = get_ethtool($intf);

    # some devices do not report settings
    # assume these are 'auto'
    return if ( ( !defined($ospeed) ) && $nspeed eq 'auto' );

    if ( defined($autoneg) && $autoneg == 1 ) {

        # Device is already in autonegotiation mode
        return if ( $nspeed eq 'auto' );
    } elsif ( defined($ospeed) && defined($oduplex) ) {

        # Device has explicit speed/duplex but they already match
        return if ( ( $nspeed eq $ospeed ) && ( $nduplex eq $oduplex ) );
    }

    my $cmd = "$ETHTOOL -s $intf";
    if ( $nspeed eq 'auto' ) {
        $cmd .= " autoneg on";
    } else {
        $cmd .= " speed $nspeed duplex $nduplex autoneg off";
    }

    exec $cmd;
    die "exec of $ETHTOOL failed: $!";
}

# Check if speed and duplex value is supported by device
sub is_supported_speed {
    my ( $dev, $speed, $duplex ) = @_;

    my $wanted = sprintf( "%dbase%s/%s",
        $speed, ( $speed == 2500 ) ? 'X' : 'T',
        ucfirst($duplex) );

    open( my $ethtool, '-|', "$ETHTOOL $dev 2>/dev/null" )
      or die "ethtool failed: $!\n";

    # ethtool output:
    #
    # Settings for eth1:
    #	Supported ports: [ TP ]
    #	Supported link modes:   10baseT/Half 10baseT/Full
    #	                        100baseT/Half 100baseT/Full
    #	                        1000baseT/Half 1000baseT/Full
    #   Supports auto-negotiation: Yes
    my $mode;
    while (<$ethtool>) {
        chomp;
        if ($mode) {
            last unless /^\t /;
        } else {
            next unless /^\tSupported link modes: /;
            $mode = 1;
        }

        return 1 if /$wanted/;
    }

    close $ethtool;
    return;
}

# Validate speed and duplex settings prior to commit
sub check_speed_duplex {
    my ( $dev, $speed, $duplex ) = @_;

    # most basic and default case
    exit 0 if ( $speed eq 'auto' && $duplex eq 'auto' );

    die "If speed is hardcoded, duplex must also be hardcoded\n"
      if ( $duplex eq 'auto' );

    die "If duplex is hardcoded, speed must also be hardcoded\n"
      if ( $speed eq 'auto' );

    die "Speed $speed, duplex $duplex not supported on $dev\n"
      unless is_supported_speed( $dev, $speed, $duplex );

    exit 0;
}

# Produce list of valid speed values for device
sub allowed_speed {
    my ($dev) = @_;

    open( my $ethtool, '-|', "$ETHTOOL $dev 2>/dev/null" )
      or die "ethtool failed: $!\n";

    my %speeds;
    my $first = 1;
    while (<$ethtool>) {
        chomp;

        if ($first) {
            next unless s/\tSupported link modes:\s//;
            $first = 0;
        } else {
            last unless /^\t /;
        }

        foreach my $val ( split / / ) {
            $speeds{$1} = 1 if $val =~ /(\d+)base/;
        }
    }

    close $ethtool;
    print 'auto ', join( ' ', sort keys %speeds ), "\n";
}

sub is_configured {
    my $ifname = shift;
    die "Missing --dev argument\n" unless $ifname;

    die "interface $ifname does not exist on the system\n"
      unless Vyatta::Interface::is_valid_intf_cfg($ifname);
    exit 0;
}

sub is_donor_internal {
    my ( $ifname, $donor_type ) = @_;
    die "Missing --dev argument\n" unless $ifname;

    die "interface $ifname does not exist on the system\n"
      unless Vyatta::Interface::is_valid_intf_cfg($ifname);

    my $intf   = new Vyatta::Interface($ifname);
    my $config = new Vyatta::Config( $intf->path() );

    my $bridge = $config->returnValue("bridge-group bridge");
    die "Can't configure unnumbered on interface that is port of bridge.\n"
      if ( defined($bridge) );

    my $bond = $config->returnValue("bond-group");
    die
"Can't configure address on interface that is slaved to bonding interface.\n"
      if ( defined($bond) );

    die "$ifname is not a valid dataplane or loopback interface name"
      unless ( ( $intf->type() eq "loopback" )
        || ( $intf->type() eq "dataplane" ) );

    my $found_addr = 0;
    my @addrs      = $config->returnValues("address");

    if ( $donor_type eq "ipv6" ) {

        my $dhcpv6 = $config->returnValue("address dhcpv6");
        die
"Can't configure unnumbered on interface that is configured for DHCPv6.\n"
          if ( defined($dhcpv6) );

        foreach my $addr (@addrs) {
            if ( Vyatta::Misc::valid_ipv6_prefix($addr) ) {
                $found_addr = 1;
            }
        }

        if ( !$found_addr ) {
            die
"Can't configure unnumbered on interface without an ipv6 address.\n";
        }
    } else {
        my $dhcp = $config->returnValue("address dhcp");
        die
"Can't configure unnumbered on interface that is configured for DHCP.\n"
          if ( defined($dhcp) );

        foreach my $addr (@addrs) {
            if ( Vyatta::Misc::valid_ip_prefix($addr) ) {
                $found_addr = 1;
            }
        }
        if ( !$found_addr ) {
            die
"Can't configure unnumbered on interface without an ip address.\n";
        }
    }
    return;
}

sub is_donor {
    is_donor_internal(@_);
    exit 0;
}

# check if interfaces are in same rd
sub check_same_routing_inst {
    my ( $s1, $s2 ) = @_;
    my $rd1 = Vyatta::Interface::get_interface_rd($s1) || 'default';
    my $rd2 = Vyatta::Interface::get_interface_rd($s2) || 'default';
    return if ( $rd1 eq $rd2 );
    die "Can't configure unnumbered on $s1 in routing-instance $rd1\n"
      . "with donor-interface $s2 in routing-instance $rd2\n";
}

sub is_check_unnumbered {
    my ( $proto_type, $ifname ) = @_;
    die "Missing --unnumbered_intf argument\n" unless $ifname;

    my $intf   = new Vyatta::Interface($ifname);
    my $config = new Vyatta::Config( $intf->path() );
    my @addrs  = $config->returnValues("address");

    my ($difname) =
      $config->listNodes("$proto_type unnumbered donor-interface");
    die "no donor-interface" unless defined($difname);
    check_same_routing_inst( $ifname, $difname );
    is_donor_internal( $difname, $proto_type );

    if ( $proto_type eq "ipv6" ) {
        foreach my $addr (@addrs) {
            die
"Can't configure unnumbered on interface that has ipv6 address configured.\n"
              if Vyatta::Misc::valid_ipv6_prefix($addr);

            die
"Can't configure unnumbered on interface that has dhcp6 configured.\n"
              if $addr eq "dhcpv6";
        }
    } else {
        foreach my $addr (@addrs) {
            die
"Can't configure unnumbered on interface that has ipv4 address configured.\n"
              if Vyatta::Misc::valid_ip_prefix($addr);

            die
"Can't configure unnumbered on interface that has dhcp configured.\n"
              if $addr eq "dhcp";
        }
    }

    exit 0;
}

sub clear_ifalias {
    my ($name) = @_;
    open my $ifalias, '>', "/sys/class/net/$name/ifalias"
      or return;
    print $ifalias "\n";
    close $ifalias;
    return;
}

# VDR specific subroutines
sub create_tap {
    my ($ifname) = @_;

    warn_failure("ip tuntap add name $ifname mode tap");

    # Create tap with link mode dormant so that when
    # it is brought up it goes into NO-CARRIER state
    # see kernel Documentation/networking/operstate.txt
    warn_failure("ip link set $ifname mode dormant")
      if ( -d "/sys/class/net/$ifname" );
}

#
# set mtu of dp interface
# Invoked whenever dp interface is created or MTU is set
# ensures that the value selected accounts for the slowpath
# overhead in case of VDR
sub set_intf_mtu {
    my ( $intf, $mtu, $action ) = @_;
    my $dpid = $intf->dpid();

    my $ifname = $intf->name();
    $mtu = $intf->mtu() unless defined($mtu);
    if ( $dpid != 0 ) {

        # when the action passed is delete, the default value is to be set
        my $config = new Vyatta::Config();
        if (
            $action eq "DELETE"
            || (   $action eq "SET"
                && $config->isDefault("interfaces dataplane $ifname mtu") )
          )
        {
            $mtu = $mtu - $VDR_SPATH_OVERHEAD;
        }
    }
    warn_failure("ip link set dev $ifname mtu $mtu")
      if ( $mtu && -d "/sys/class/net/$ifname" );

    return $mtu;
}

# Create new virtual endpoint
# If local and remote IP are different, them make the tunnel
# otherwise it is assumed to exist (ie TAP device)
sub create_device {
    my $ifname = shift;
    my $intf   = new Vyatta::Interface($ifname);
    my $dpid   = $intf->dpid();

    if ( defined($dpid) && $dpid != 0 ) {
        if ( !-d "/sys/class/net/$ifname" ) {
            create_tap($ifname);
        }
    }

    Vyatta::Interface::vrf_bind_one($ifname);
}

# Check configuration of the device
sub check_device {
    my $ifname = shift;

    return unless eval 'use Vyatta::DistributedDataplane; 1';

    my $intf = new Vyatta::Interface($ifname);

    die "$ifname is not a valid dataplane interface name\n"
      unless ( $intf->is_dp_type_interface() );

    my $dpid = $intf->dpid();
    return 1 if ( $dpid == 0 );

    my $cfg      = Vyatta::Config->new('distributed');
    my $localip  = Vyatta::DistributedDataplane::get_controller_ip($cfg);
    my $remoteip = Vyatta::DistributedDataplane::get_vplane_ip( $dpid, $cfg );

    #
    # The VDR controller and dataplane addresses are mandatory. Thus if
    # the top-level controller and dataplane objects exist, the
    # associated addresses will also exist.
    #
    if ( $cfg->exists('controller') ) {
        die "dataplane $dpid is not configured\n"
          unless $cfg->exists("dataplane $dpid");

        return 1;
    }

    #
    # The interface DPID is non-zero, yet we have no VDR configuration;
    # provided the endpoint addresses have been defined (in the .conf
    # files, see above), accept the interface. Must be some sort of
    # "hand-crafted" distributed system.
    #
    die "IP address for controller is not configured\n"
      unless ( defined($localip) );

    die "IP address for dataplane $dpid is not configured\n"
      unless ( defined($remoteip) );

    return 1;
}

sub delete_device {
    my $ifname = shift;
    my $intf   = new Vyatta::Interface($ifname);

    die "$ifname is not a valid dataplane interface name"
      unless ( $intf->is_dp_type_interface() );

    # remove stats files for this device
    my $stats_dir = "/var/run/vyatta";
    remove( "$stats_dir/$ifname.stats", "$stats_dir/$ifname.*.stats" );

    # already deleted?
    return unless ( -d "/sys/class/net/$ifname" );

    system("ip link set dev $ifname down");

    # Expect this to be managed by dataplane
    return if ( $intf->dpid() == 0 );

    system("ip link del dev $ifname") == 0
      or die "Can't delete $ifname";
}

sub validate_device_internal {
    my ( $dev, $vif_check, @addrs );

    $dev       = shift;
    $vif_check = shift;
    @addrs     = @_;

    # Only check if requested.
    check_vifs($dev) if $vif_check;

    # VDR specific checks
    if ( check_device($dev) and $addrs[0] ne "" ) {
        is_valid_addr_commit( $dev, @addrs );
    }
}

sub validate_device {
    my ( $dev, @addrs );

    $dev   = shift;
    @addrs = @_;

    die "Missing --dev option" unless $dev;

    validate_device_internal( $dev, 1, @addrs );
}

# Similar to validate_device, but for dataplane interface where we know that
# the check_vifs() logic will be performed by the VIF YANG and so no need to
# duplicate here.
sub validate_dp_device {
    my ( $dev, @addrs );

    $dev   = shift;
    @addrs = @_;

    die "Missing --dev option" unless $dev;

    validate_device_internal( $dev, 0, @addrs );
}

sub update_dev_mtu {
    my ( $name, $mtu, $action ) = @_;
    my $intf = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    my $config = new Vyatta::Config( $intf->path() );

    my $bond;

    if ( $action eq "DELETE" ) {
        $bond = $config->returnOrigValue("bond-group");
    } else {
        $bond = $config->returnValue("bond-group");
    }

    return if ( defined($bond) );

    # set dev mtu
    $mtu = set_intf_mtu( $intf, $mtu, $action );

    # set underlying vif mtu.
    # when setting parent mtu to be value less than the default,
    # linux sets all the vif's mtu to be that smaller value,
    # but it never restores the original mtu when the parent's
    # set underlying vif mtu.
    foreach my $id ( $config->listNodes("vif") ) {
        my $vlan       = $config->returnValue("vif $id vlan");
        my $inner_vlan = $config->returnValue("vif $id inner-vlan");
        my $vif_mtu    = $config->returnValue("vif $id mtu");
        my $vifname    = "$name.$id";

        if ( defined($inner_vlan) ) {
            my $outer_vname = "$name.0$vlan";

            warn_failure("ip link set $outer_vname mtu $mtu")
              if ( ( -e "/sys/class/net/$outer_vname/mtu" )
                && get_sysfs_value( "$outer_vname", "mtu" ) != $mtu );
        }

        if ( !defined($vif_mtu) ) {
            $vif_mtu = $mtu;
        }

        $vif_mtu = $mtu if ( $vif_mtu > $mtu );
        warn_failure("ip link set $vifname mtu $vif_mtu")
          if ( -d "/sys/class/net/$vifname" );
    }
}

sub process_breakout {
    my ( $action, $subports, $intf, $reservedintf ) = @_;

    return unless eval 'use Vyatta::VPlaned; 1';
    return unless eval 'use vyatta::proto::BreakoutConfig; 1';

    my $ctrl = new Vyatta::VPlaned;
    my $action_type;

    $action_type = BreakoutConfig::Action::DELETE() if ( $action eq 'DELETE' );
    $action_type = BreakoutConfig::Action::SET()    if ( $action eq 'SET' );

    my $msg = BreakoutConfig->new(
        {
            breakoutif => BreakoutConfig::BreakoutIfConfig->new(
                {
                    ifname         => $intf,
                    action         => $action_type,
                    numsubports    => $subports,
                    reservedifname => $reservedintf,
                }
            ),
        }
    );

    $ctrl->store_pb( "breakout $intf", $msg, "vyatta:breakout", $intf,
        $action );
}
