# Author: Stephen Hemminger <shemminger@vyatta.com>
# Date: 2009
# Description: vyatta interface management

# **** License ****
# Copyright (c) 2017-2020 AT&T Intellectual Property.
#    All Rights Reserved.
#
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
# **** End License ****

package Vyatta::Interface;

use strict;
use warnings;
use Readonly;

use File::Slurp;
use IO::Interface;
use List::Util qw/reduce/;
use Try::Tiny;

use NetAddr::IP;
use Vyatta::Misc;
use Vyatta::Config;
use Vyatta::Configd;
use base 'Exporter';

our @EXPORT = qw(IFF_UP IFF_BROADCAST IFF_DEBUG IFF_LOOPBACK
  IFF_POINTOPOINT IFF_RUNNING IFF_NOARP
  IFF_PROMISC IFF_MULTICAST validate_dev_mtu add_interface_redirect);

my $has_vrf;

BEGIN {
    if ( eval { require Vyatta::VrfManager; 1 } ) {
        $has_vrf = 1;
    }
}

use constant {
    IFF_UP          => 0x1,        # interface is up
    IFF_BROADCAST   => 0x2,        # broadcast address valid
    IFF_DEBUG       => 0x4,        # turn on debugging
    IFF_LOOPBACK    => 0x8,        # is a loopback net
    IFF_POINTOPOINT => 0x10,       # interface is has p-p link
    IFF_NOTRAILERS  => 0x20,       # avoid use of trailers
    IFF_RUNNING     => 0x40,       # interface RFC2863 OPER_UP
    IFF_NOARP       => 0x80,       # no ARP protocol
    IFF_PROMISC     => 0x100,      # receive all packets
    IFF_ALLMULTI    => 0x200,      # receive all multicast packets
    IFF_MASTER      => 0x400,      # master of a load balancer
    IFF_SLAVE       => 0x800,      # slave of a load balancer
    IFF_MULTICAST   => 0x1000,     # Supports multicast
    IFF_PORTSEL     => 0x2000,     # can set media type
    IFF_AUTOMEDIA   => 0x4000,     # auto media select active
    IFF_DYNAMIC     => 0x8000,     # dialup device with changing addresses
    IFF_LOWER_UP    => 0x10000,    # driver signals L1 up
    IFF_DORMANT     => 0x20000,    # driver signals dormant
    IFF_ECHO        => 0x40000,    # echo sent packets
};

# VDR uses VXLAN-GPE + NSH for originating/terminating traffic
# to/from the controller. So, the extra slowpath header size is
#     IPv4 : IPv4 + UDP + VxLAN-GPE + NSH (inc ifindex metadata)
#            20   + 8   + 8         + 16 = 52 bytes
#     IPv6 : IPv6 + UDP + VxLAN-GPE + NSH (inc ifindex metadata)
#            40   + 8   + 8         + 16 = 72 bytes
# In addition, we also need to allow for 14 bytes for the L2 hdr of the payload
# Since we cannot make config more restrictive later, allow for a maximum
# slowpath overhead of 100 bytes
Readonly::Scalar our $VDR_SPATH_OVERHEAD => 100;
our @EXPORT_OK = qw( $VDR_SPATH_OVERHEAD );

# Build list of known interface types
my $NETDEV = '/opt/vyatta/etc/netdevice';

# Hash of interface types
# ex: $net_prefix{"dp"} = "dataplane"
my %net_prefix;

sub parse_netdev_file {
    my $filename = shift;

    open( my $in, '<', $filename )
      or return;

    while (<$in>) {
        chomp;

        # remove text after # as comment
        s/#.*$//;

        my ( $prefix, $type ) = split;

        # ignore blank lines or missing patterns
        next unless defined($prefix) && defined($type);

        $net_prefix{$prefix} = $type;
    }
    close $in;
}

# read /opt/vyatta/etc/netdevice
parse_netdev_file($NETDEV);

# look for optional package interfaces in /opt/vyatta/etc/netdevice.d
my $dirname = $NETDEV . '.d';
if ( opendir( my $netd, $dirname ) ) {
    foreach my $pkg ( sort readdir $netd ) {
        parse_netdev_file( $dirname . '/' . $pkg );
    }
    closedir $netd;
}

sub find_netdevice_type {
    my ( $device_types, $ifname ) = @_;
    my %matches = map { $ifname =~ /^($_)/; $_ => $1 }
      grep { $ifname =~ /^$_/ } keys(%$device_types);
    my $key =
      reduce { length( $matches{$a} ) > length( $matches{$b} ) ? $a : $b }
    keys(%matches);
    return unless defined $key;
    return $device_types->{$key};
}

# get list of interface types (only used in usage function)
sub interface_types {
    return values %net_prefix;
}

# new interface description object
sub new {
    my $that  = shift;
    my $name  = pop;
    my $class = ref($that) || $that;

    my ( $vif, $vrid, $dpid );
    my $dev = $name;

    if ( index( $name, "vrrp" ) != -1 ) {
        my $config = Vyatta::Configd::Client->new();
        my $transmit_intf;
        try {
            $transmit_intf =
              $config->call_rpc_hash( "vyatta-vrrp-v1", "rfc-intf-map",
                { "transmit" => $name } );
        }
        catch {
            system("logger Failed to find transmit interface for $name\n");
            return;
        };
        return unless($transmit_intf->{"receive"} && $transmit_intf->{"group"});
        $dev  = $transmit_intf->{"receive"};
        $vrid = $transmit_intf->{"group"};
        if ( $vrid == 0 ) {

            #keepalived is not running so return
            return;
        }
    }

    # remove VLAN suffix
    if ( $dev =~ /^(.*)\.(\d+)/ ) {
        $dev = $1;
        $vif = $2;
    }

    # convert from prefix  to type
    my $type = find_netdevice_type( \%net_prefix, $dev );
    return unless $type;    # unknown network interface type

    if (    ( ( $type eq 'dataplane' ) or ( $type eq 'uplink' ) )
        and ( $dev =~ /^[a-z]+(\d+)/ ) )
    {
        $dpid = $1;
    }

    # this does not fit the "prefix" approach to device naming
    $type = "bonding" if ( $dev =~ /dp[0-9]+bond/ );
    $type = "vhost"   if ( $dev =~ /dp[0-9]+vhost/ );

    my $self = {
        name => $name,
        type => $type,
        dev  => $dev,
        dpid => $dpid,
        vif  => $vif,
        vrid => $vrid,
    };
    $self->{path} = path($self);
    bless $self, $class;
    return $self;
}

## Field accessors
sub name {
    my $self = shift;
    return $self->{name};
}

sub path {
    my $self = shift;

    # normal device
    my $path = "interfaces $self->{type} $self->{dev}";
    $path .= " vrrp $self->{vrid}" if $self->{vrid};
    $path .= " vif $self->{vif}"   if $self->{vif};

    return $path;
}

sub type {
    my $self = shift;
    return $self->{type};
}

sub vif {
    my $self = shift;
    return $self->{vif};
}

sub dpid {
    my $self = shift;
    return $self->{dpid};
}

sub vrid {
    my $self = shift;
    return $self->{vrid};
}

sub physicalDevice {
    my $self = shift;
    return $self->{dev};
}

## Configuration checks

sub configured {
    my $self   = shift;
    my $client = Vyatta::Configd::Client->new();

    return $client->node_exists( $Vyatta::Configd::Client::AUTO, $self->{path} );
}

sub disabled {
    my $self   = shift;
    my $config = Vyatta::Config->new( $self->{path} );

    return $config->exists("disable");
}

sub mtu {
    my $self   = shift;
    my $config = Vyatta::Config->new( $self->{path} );

    return $config->returnValue("mtu");
}

sub vlan {
    my $self = shift;

    if ( defined( $self->{vif} ) ) {
        my $config = Vyatta::Config->new();
        $config->setLevel(
            "interfaces $self->{type} $self->{dev} vif $self->{vif}");

        my $vlan     = $config->returnOrigValue("vlan");
        $vlan = $self->{vif} if !defined $vlan;
        my $inner    = $config->returnOrigValue("inner-vlan");
        my $vlan_str = defined($inner) ? $vlan . '.' . $inner : $vlan;

        return $vlan_str;
    }

    return "";
}

sub using_dhcp {
    my $self   = shift;
    my $config = Vyatta::Config->new( $self->{path} );

    my @addr = grep { $_ eq 'dhcp' } $config->returnOrigValues('address');

    return if ( $#addr < 0 );
    return $addr[0];
}

sub bridge_grp {
    my $self   = shift;
    my $config = Vyatta::Config->new( $self->{path} );

    return $config->returnValue("bridge-group bridge");
}

## System checks

# return array of current addresses (on system)
sub address {
    my ( $self, $type ) = @_;

    return Vyatta::Misc::getIP( $self->{name}, $type );
}

# Do SIOCGIFFLAGS ioctl in C wrapper
# Can't use /sys/class/net/<name>/flags due to how operstate
# is handled in the kernel.
sub flags {
    my $self = shift;
    print "Don't use the Vyatta::Interface::flags subroutine in a LIST context"
      if wantarray;

    my $sock = IO::Socket::INET->new( Proto => 'udp' );
    my $flags = $sock->if_flags( $self->{name} );
    return $flags if $flags;
    return;
}

sub exists {
    my $self  = shift;
    my $flags = $self->flags();
    return defined($flags);
}

sub hw_address {
    my $self = shift;

    open my $addrf, '<', "/sys/class/net/$self->{name}/address"
      or return;
    my $address = <$addrf>;
    close $addrf;

    chomp $address if $address;
    return $address;
}

sub bandwidth {
    my $self = shift;

    my $bw =
      read_file( "/sys/class/net/$self->{name}/speed", err_mode => 'quiet' );

    chomp $bw if $bw;
    return $bw;
}

sub is_broadcast {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_BROADCAST );
}

sub is_multicast {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_MULTICAST );
}

sub is_pointtopoint {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_POINTOPOINT );
}

sub is_loopback {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_LOOPBACK );
}

# device exists and is online
sub up {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_UP );
}

# device exists and is running (ie carrier present)
sub running {
    my $self  = shift;
    my $flags = $self->flags();

    return defined($flags) && ( $flags & IFF_RUNNING );
}

# Return RFC2863 operational state
#
# See kernel/Documentation/ABI/testing/sysfs-class-net for possible
# return strings
sub operstate {
    my $self       = shift;
    my $statusfile = "/sys/class/net/$self->{name}/operstate";
    open( my $fh, '<', $statusfile ) or return "unknown";
    my $status = <$fh>;
    close($fh);
    chomp($status);
    return $status;
}

sub opstate_changes {
    my $self = shift;

    return Vyatta::Misc::get_sysfs_value( $self->{name}, "opstate_changes" );
}

sub opstate_age {
    my $self = shift;

    return Vyatta::Misc::get_sysfs_value( $self->{name}, "opstate_age" );
}

# device description information in kernel (future use)
sub description {
    my $self = shift;

    return interface_description( $self->{name} );
}

sub ignore_addr {
    my ( $ifname, $addr ) = @_;
    my $ip = new NetAddr::IP($addr);
    die "not a valid IP address '$addr'" unless defined($ip);

    # skip link local
    if ( $ip->version() == 6 ) {
        my $link_local_net = new NetAddr::IP('fe80::/10');
        return 1 if $ip->within($link_local_net);
    }

    if ( $ifname eq 'lo' ) {
        my $loop =
          $ip->version() == 4
          ? NetAddr::IP->new('loopback')
          : NetAddr::IP->new6('loopback');

        return $ip eq $loop;
    }

    return;    # ok
}

sub get_ipaddr_list {
    my $self = shift;

    # Skip local addresses and loopback on lo
    return
      grep { !ignore_addr( $self->{name}, $_ ) }
      Vyatta::Misc::getIP( $self->{name} );

}

# device routing domain
sub rdid {
    my $self = shift;
    return eval {

        # Equal to $VRFID_DEFAULT
        return 1 if !$has_vrf;
        return Vyatta::VrfManager::get_interface_vrf_id( $self->{name} );
    };
}

sub vrf {
    my $self = shift;
    return eval {

        # Equal to $VRFNAME_DEFAULT
        return 'default' if !$has_vrf;
        return Vyatta::VrfManager::get_interface_vrf( $self->{name} );
    };
}

# Command prefix to run a command in the VRF context for the interface
sub vrf_cmd_prefix {
    my $self = shift;
    return Vyatta::Misc::VrfCmdPrefix( $self->{name} );
}

## Utility functions

# enumerate vrrp slave devices
sub get_vrrp_interfaces {
    my ( $cfg, $vfunc, $dev, $path ) = @_;
    my @ret_ifs;

    foreach my $vrid ( $cfg->$vfunc("$path vrrp vrrp-group") ) {
        my $vrdev  = $dev . "v" . $vrid;
        my $vrpath = "$path vrrp vrrp-group $vrid interface";

        push @ret_ifs,
          {
            name => $vrdev,
            type => 'vrrp',
            path => $vrpath,
          };
    }

    return @ret_ifs;
}

# enumerate vif devies
sub get_vif_interfaces {
    my ( $cfg, $vfunc, $dev, $type, $path ) = @_;
    my @ret_ifs;

    foreach my $vnum ( $cfg->$vfunc("$path vif") ) {
        my $vifdev  = "$dev.$vnum";
        my $vifpath = "$path vif $vnum";
        push @ret_ifs,
          {
            name => $vifdev,
            type => $type,
            path => $vifpath
          };
        push @ret_ifs, get_vrrp_interfaces( $cfg, $vfunc, $vifdev, $vifpath );
    }

    return @ret_ifs;
}

# get all configured interfaces from configuration
# parameter is virtual function (see Config.pm)
#
# return a hash of:
#   name => ethX
#   type => "ethernet"
#   path => "interfaces ethernet ethX"
#
# Don't use this function directly, use wrappers below instead
sub get_config_interfaces {
    my $vfunc = shift;
    my $cfg   = Vyatta::Config->new();
    my @ret_ifs;

    foreach my $type ( $cfg->$vfunc("interfaces") ) {
        foreach my $dev ( $cfg->$vfunc("interfaces $type") ) {
            my $path = "interfaces $type $dev";

            push @ret_ifs,
              {
                name => $dev,
                type => $type,
                path => $path
              };
            push @ret_ifs, get_vrrp_interfaces( $cfg, $vfunc, $dev, $path );
            push @ret_ifs,
              get_vif_interfaces( $cfg, $vfunc, $dev, $type, $path );
        }

    }

    return @ret_ifs;
}

# get array of hash for interfaces in working config
sub get_interfaces {
    return get_config_interfaces('listNodes');
}

# get array of hash for interfaces in configuration
# when used outside of config mode.
sub get_effective_interfaces {
    return get_config_interfaces('listEffectiveNodes');
}

# get array of hash for interfaces in original config
# only makes sense in configuration mode
sub get_original_interfaces {
    return get_config_interfaces('listOrigNodes');
}

sub get_interface_names {
    return map { $_->{'name'} } get_interfaces();
}

# returns configured routing-instnace of an interface
sub get_interface_rd {
    my $ifname = shift;
    my $cfg    = Vyatta::Config->new();
    my $p      = 'routing routing-instance';

    if ( $cfg->inSession() ) {
        foreach my $rd ( $cfg->listNodes($p) ) {
            return $rd if $cfg->exists("$p $rd interface $ifname");
        }
    } else {
        foreach my $rd ( $cfg->listEffectiveNodes($p) ) {
            return $rd if $cfg->isActive("$p $rd interface $ifname");
        }
    }
    return;
}

# gets a map of interfaces to routing instance for all non-default
# routing instance.
# do not use this function directly.
sub get_config_intf_rd_map {
    my ( $cfg, $vfunc ) = @_;
    my %result = ();
    my $p      = "routing routing-instance";
    foreach my $rd ( $cfg->$vfunc($p) ) {
        foreach my $rdif ( $cfg->$vfunc("$p $rd interface") ) {
            $result{$rdif} = $rd;
        }
    }
    return \%result;
}

sub get_intf_rd_map {
    my $cfg = shift;
    return get_config_intf_rd_map( $cfg, "listNodes" );
}

sub get_intf_rt_inst_fn_for_map {
    my $h = shift;
    return sub { return $h->{ $_[0] } if exists( $h->{ $_[0] } ); return; };
}

# returns a closure for finding routing instance
sub get_intf_rt_inst_fn {
    my $cfg = shift;
    return unless $cfg->exists("routing routing-instance");
    return get_intf_rt_inst_fn_for_map( get_intf_rd_map($cfg) );
}

sub get_orig_intf_rd_map {
    my $cfg = shift;
    return get_config_intf_rd_map( $cfg, "listOrigNodes" );
}

# returns a closure for finding original routing instance
sub get_orig_intf_rt_inst_fn {
    my $cfg = shift;
    return unless $cfg->existsOrig("routing routing-instance");
    return get_intf_rt_inst_fn_for_map( get_orig_intf_rd_map($cfg) );
}

# get the address from ifhash
# work around for openvpn.
sub get_interface_cfg_addr {
    my ( $ifh, $cfg ) = @_;
    $cfg = Vyatta::Config->new() unless defined($cfg);
    if ( $ifh->{type} ne 'openvpn' ) {
        return $cfg->returnValues( $ifh->{path} . " address" );
    }
    return $cfg->listNodes( $ifh->{path} . " local-address" );
}

#internal function..
sub add_to_addrmap {
    my ( $h, $k, $v, $fn ) = @_;
    my $rt;

    $rt = $fn->($v) if defined($fn);
    $k .= ",$rt" if defined($rt);
    $h->{$k} = [] unless exists( $h->{$k} );
    push @{ $h->{$k} }, $v;
    return;
}

# returns two hash refs
# { 1.1.1.1 => (eth0, eth1) },
# { 1.1.1.1/24 => (eth0, eth1) }
# returns a arrayref in scalar context
sub get_cfg_addrmap {
    my $config   = Vyatta::Config->new();
    my $if2rt_fn = get_intf_rt_inst_fn($config);
    my @cfgifs   = get_interfaces();
    my $ahash    = {};
    my $phash    = {};

    foreach my $intf (@cfgifs) {
        my $name = $intf->{'name'};
        foreach my $addr ( get_interface_cfg_addr( $intf, $config ) ) {
            next
              if ( $addr =~ /^dhcp/ );

            my $ip = NetAddr::IP->new($addr);
            add_to_addrmap( $ahash, $ip->addr,    $name, $if2rt_fn );
            add_to_addrmap( $phash, $ip->network, $name, $if2rt_fn );
        }
    }
    return wantarray ? ( $ahash, $phash ) : [ $ahash, $phash ];
}

# validate the interface given by interface name is currently
# configured.
#
sub is_valid_intf_cfg {
    my $name = shift;
    my $found = grep { $_ eq $name } get_interface_names();

    return $found;
}

# $intf - interface hash
# $action - (Orig|Effective|)
# Returns a list of interface addresses.
# Do not call directly - use the wrappers below
sub get_config_interface_addrs {
    my ( $intf, $vfn ) = @_;
    my $config = Vyatta::Config->new( $intf->{'path'} );

    my $nodefn  = "list${vfn}Nodes";
    my $valuefn = "return${vfn}Values";

    # workaround openvpn wart
    my @addrs;
    my $name = $intf->{'name'};
    if ( $name =~ /^vtun/ ) {
        @addrs = $config->$nodefn('local-address');
    } else {
        @addrs = $config->$valuefn('address');
    }
    if (@addrs) {
        push @addrs,
          get_vrrp_interface_addrs( $config, $intf->{'path'}, $addrs[0], $vfn );
    }
    return @addrs;
}

# Return the list of VRRP addresses on the interface (non rfc mode)
# $cfg - config object
# $path - Path to config level
# $lead_addr - the first ip address on the interface (used for a VRRP special case)
sub get_vrrp_interface_addrs {
    my ( $cfg, $path, $lead_addr, $vfn ) = @_;
    my @ret_addrs;
    $lead_addr =~ m/(.*?)\/(.*)/;
    my $lead_prefix = $2;

    my $nodefn  = "list${vfn}Nodes";
    my $valuefn = "return${vfn}Values";
    my $existfn = "exists${vfn}";

    my $vrrp_path = "$path vrrp vrrp-group";
    $cfg->setLevel($vrrp_path);
    my $groups = $cfg->$nodefn();
    foreach my $vrid ($groups) {
        $cfg->setLevel("$path vrrp vrrp-group $vrid");
        my $vmac_interface = $cfg->$existfn("rfc-compatibility");

        # VRRP VIPs are only added when we aren't in rfc mode.
        if ( !defined $vmac_interface ) {
            foreach my $vip ( $cfg->$valuefn("virtual-address") ) {
                my $prefix = 0;
                if ( $vip =~ m/(.*?)\/(.*)/ ) {
                    $prefix = $2;
                }

                my $full_prefix = 32;
                if ( Vyatta::Misc::is_ip_v4_or_v6($vip) == 6 ) {
                    $full_prefix = 128;
                }

        # Special Case 1: If a VRRP address is added without a prefix
        # then it appears with a full prefix in the config so it must be removed
        # with a full prefix (either /32 or /128 depending on AF)
                if ( !( $vip =~ /\// ) ) {
                    $vip = $vip . "/$full_prefix";
                }

   # Special Case 2: If a VRRP address is added with a prefix that
   # matches the prefix of the first IP address on the interface
   # it is instead added with a full prefix (either /32 or /128 depending on AF)
                if ( $lead_prefix == $prefix ) {
                    $vip =~ s/\/(\d+)/\/$full_prefix/;
                }
                push @ret_addrs, $vip;
            }
        }
    }

    return @ret_addrs;
}

sub get_interface_addrs {
    my $intf = shift;
    return get_config_interface_addrs( $intf, '' );
}

sub get_orig_interface_addrs {
    my $intf = shift;
    return get_config_interface_addrs( $intf, 'Orig' );
}

sub get_effective_interface_addrs {
    my $intf = shift;
    return get_config_interface_addrs( $intf, 'Effective' );
}

sub vrf_bind_one {
    eval { require Vyatta::VRFInterface; } or return;
    return Vyatta::VRFInterface::vrf_bind_one(@_);
}

sub is_dp_type_interface {
    my $self = shift;
    return (
             ( $self->type() eq 'dataplane' )
          or ( $self->type() eq 'uplink' )
    );
}

sub get_controller_fabric_addr {
    my $config = shift;

    my @fabric_addrs =
      $config->returnValues("distributed controller fabric address");

    return $fabric_addrs[0];
}

# validate_dev_mtu
# Invoked for dpXXX interfaces on VDR
# ensures that the mtu configured allows for slowpath overhead
sub validate_dev_mtu {
    my ( $ifname, $mtu, $action ) = @_;
    my ( $warn, $err ) = validate_dev_mtu_silent( $ifname, $mtu, $action );
    die($err)   unless ( $err eq "" );
    warn($warn) unless ( $warn eq "" );
}

# Returns (warn, err). Allows caller to bundle up multiple warnings
# and errors to print.
sub validate_dev_mtu_silent {
    my ( $ifname, $mtu, $action ) = @_;

    my $intf = new Vyatta::Interface($ifname);
    my $dpid = $intf->dpid();
    if ( $dpid != 0 ) {
        my $config  = new Vyatta::Config();
        my $mtu_min = $mtu + $VDR_SPATH_OVERHEAD;

        # Get fabric interface cfg
        my $fabric_ip = get_controller_fabric_addr($config);
        my ( $fab_ifname, $fab_mtu, $fab_mtu_default ) =
          Vyatta::Address::get_system_interface( $fabric_ip, "fabric" );

        my $dp_default =
          defined( $config->isDefault("interfaces dataplane $ifname mtu") );
        if ( !$dp_default ) {
            return ( "",
                "Fabric interface $$fab_ifname must have mtu >= $mtu_min\n" )
              unless ( $$fab_mtu >= $mtu_min );
        } else {
            if ( !$$fab_mtu_default ) {
                my $mtu_max = $$fab_mtu - $VDR_SPATH_OVERHEAD;
                return (
                    "MTU of fabric interface $$fab_ifname = $$fab_mtu\n"
                      . "MTU of $ifname should be reduced to $mtu_max or "
                      . "lower\n",
                    ""
                ) unless ( $mtu_max >= $mtu );
            }
        }
    }
    return ( "", "" );
}

sub check_dataplane_mtu {
    my $cfg = shift;

    my ( %err_map, %warn_map );

    # Dataplane interface validation.
    foreach my $dpInt ( $cfg->listNodes("interfaces dataplane") ) {

        # Check MTU.  Note that the action is always 'SET' as in the
        # 'delete' case we are actually setting the default value.
        my $mtu = $cfg->returnValue("interfaces dataplane $dpInt mtu");
        my ( $warn, $err ) = validate_dev_mtu_silent( $dpInt, $mtu, 'SET' );
        $err_map{$dpInt} = 'interfaces dataplane ' . $dpInt . ': ' . $err
          unless $err eq "";
        $warn_map{$dpInt} = 'interfaces dataplane ' . $dpInt . ': ' . $warn
          unless $warn eq "";
    }

    foreach my $name ( sort keys %err_map ) {
        printf "%s\n", $err_map{$name};
    }
    foreach my $name ( sort keys %warn_map ) {
        printf "%s\n", $warn_map{$name};
    }

    my $num_errs  = keys %err_map;
    my $num_warns = keys %warn_map;

    return ( $num_errs, $num_warns );
}

sub warn_failure {
    my $cmd = shift;
    system($cmd) == 0 or warn "'$cmd' failed\n";
}

sub add_interface_redirect {
    my ( $intf, $create_time ) = @_;

    if ($create_time) {
        warn_failure("tc qdisc add  dev $intf handle 1: root prio");
    } else {

        # Rule refresh. Delete the old redirect as the target .spathintf
        # has been recreated. The base qdisc does not require updating
        warn_failure("tc filter del dev $intf parent 1:");
    }

    if ( -d "/sys/class/net/.spathintf" ) {
        my $cmd = "tc filter add  dev $intf parent 1: protocol all u32";
        $cmd = $cmd . " match u8 0 0 action mirred egress redirect ";
        $cmd = $cmd . "dev .spathintf";

        warn_failure($cmd)

    }
}

-1;
