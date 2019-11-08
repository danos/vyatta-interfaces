# Module: VyattaMisc.pm
#
# Author: Marat <marat@vyatta.com>
# Date: 2007
# Description: Implements miscellaneous commands

# **** License ****
# Copyright (c) 2019 AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
# **** End License ****

package Vyatta::Misc;
use strict;
use POSIX;
use Vyatta::ioctl;

require Exporter;

our @ISA    = qw(Exporter);
our @EXPORT = qw(getInterfaces getIP getNetAddIP get_sysfs_value get_timestr
  is_address_enabled
  get_intf_cfg_addr isIpAddress is_ip_v4_or_v6 interface_description
  is_local_address
  isValidPortNumber get_terminal_height
  get_terminal_width is_addr_loopback valid_ip_addr valid_ipv6_addr
  valid_ip_prefix valid_ipv6_prefix is_link_local filter_link_local_loopback
  is_addr_multicast);
our @EXPORT_OK = qw(getInterfacesIPAddresses getPortRuleString);

use Vyatta::Config;
use Vyatta::Interface;
use NetAddr::IP;
use Socket;

sub get_sysfs_value {
    my ( $intf, $name ) = @_;

    open( my $statf, '<', "/sys/class/net/$intf/$name" )
      or return;

    my $value = <$statf>;
    chomp $value if defined $value;
    close $statf;
    return $value;
}

sub get_timestr {
    my $t = shift;

    return strftime( "%Y-%m-%dT%T%z", localtime($t) );
}

# check if any non-dhcp addresses configured
sub is_address_enabled {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    $intf or return;

    my $config = new Vyatta::Config;
    $config->setLevel( $intf->path() );
    foreach my $addr ( $config->returnOrigValues('address') ) {
        return 1 if ( $addr && $addr ne 'dhcp' );
    }

    return;
}

# get list of interfaces on the system via sysfs
# skip bond_masters file used by bonding and wireless
# control interfaces and skip vrf master devices
sub getInterfaces {
    opendir( my $sys_class, '/sys/class/net' )
      or die "can't open /sys/class/net: $!";
    my @interfaces =
      grep { -l "/sys/class/net/$_" && !/^\./ && !/^vrf/ } readdir $sys_class;
    closedir $sys_class;
    return @interfaces;
}

# Test if IP address is local to the system.
# Implemented by doing bind since by default
# Linux will only allow binding to local addresses
sub is_local_address {
    my $addr = shift;
    my $ip   = new NetAddr::IP $addr;
    die "$addr: not a valid IP address"
      unless $ip;

    my ( $pf, $sockaddr );
    if ( $ip->version() == 4 ) {
        $pf = PF_INET;
        $sockaddr = sockaddr_in( 0, $ip->aton() );
    } else {
        $pf = PF_INET6;
        $sockaddr = sockaddr_in6( 0, $ip->aton() );
    }

    socket( my $sock, $pf, SOCK_STREAM, 0 )
      or die "socket failed\n";

    return bind( $sock, $sockaddr );
}

# Filter for skipping link local and loopback addresses
sub filter_link_local_loopback {
    my $addr = shift;

    # skip link local addresses
    return 1 if is_link_local($addr);

    # skip loopback addresses
    return is_addr_loopback($addr);
}

# Command prefix to run a command in the VRF context for the interface
sub VrfCmdPrefix {
    my $intf = new Vyatta::Interface(shift);
    return unless $intf;
    my $vrf = $intf->vrf();
    unless ( defined($vrf) && !($vrf eq 'default') ) {
        return wantarray ? () : '';
    }
    return ( qw(chvrf), $vrf ) if wantarray;
    return "chvrf $vrf ";
}

# get list of IPv4 and IPv6 addresses
# if name is defined then get the addresses on that interface
# if type is defined then restrict to that type (inet, inet6)
# if filter is defined then call fn reference to restrict based on
# $addr (see filter_link_local_loopback as example)
sub getIP {
    my ( $name, $type, $filter ) = @_;
    my @addresses;

    my @args = ( VrfCmdPrefix($name) );
    push @args, qw(/bin/ip addr show);
    push @args, ( 'dev', $name ) if $name;

    open my $ipcmd, '-|'
      or exec @args
      or die "ip addr command failed: $!";

    <$ipcmd>;
    while (<$ipcmd>) {
        my ( $proto, $addr ) = split;
        next unless ( $proto =~ /inet/ );
        if ($type) {
            next if ( $proto eq 'inet6' && $type != 6 );
            next if ( $proto eq 'inet'  && $type != 4 );
        }
        next if ( $filter && $filter->($addr) );

        my $ptp_prefix = '/32';
        if ( $proto eq 'inet6' ) {
            $ptp_prefix = '/128';
        }
        $addr .= $ptp_prefix unless ( $addr =~ /\// );

        push @addresses, $addr;
    }
    close $ipcmd;

    return @addresses;
}

# get list of config IPv4 and IPv6 address, including
# "address dhcp" and "address dhcpv6"
sub get_intf_cfg_addr {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    return unless $intf;

    my @cfg_addr;
    my $config = new Vyatta::Config;

    $config->setLevel( $intf->path() );

    # the "effective" observers can be used both inside and outside
    # config sessions.
    foreach my $addr ( $config->returnEffectiveValues('address') ) {
        push @cfg_addr, $addr;
    }

    return @cfg_addr;
}

my %type_hash = (
    'broadcast'    => 'is_broadcast',
    'multicast'    => 'is_multicast',
    'pointtopoint' => 'is_pointtopoint',
    'loopback'     => 'is_loopback',
);

# getInterfacesIPAddresses() returns IPv4 and IPv6 addresses for the interface type
# possible type of interfaces : 'broadcast', 'pointtopoint', 'multicast', 'all'
# and 'loopback'
sub getInterfacesIPAddresses {
    my ( $type, $addr_type ) = @_;
    my $type_func;
    my @ips;

    $type or die "Interface type not defined";

    if ( $type ne 'all' ) {
        $type_func = $type_hash{$type};
        die "Invalid type specified to retreive IP addresses for: $type"
          unless $type_func;
    }

    foreach my $name ( getInterfaces() ) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf;
        if ( defined $type_func ) {
            next unless $intf->$type_func();
        }

        my @addresses = $intf->address($addr_type);
        push @ips, @addresses;
    }
    return @ips;
}

sub getNetAddrIP {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    $intf or return;

    foreach my $addr ( $intf->addresses() ) {
        my $ip = new NetAddr::IP $addr;
        next unless ( $ip && ip->version() == 4 );
        return $ip;
    }

    return;
}

sub is_ip_v4_or_v6 {
    my $addr = shift;

    my $ip = new NetAddr::IP $addr;
    return unless defined $ip;

    my $vers = $ip->version();
    if ( $vers == 4 ) {

        #
        # NetAddr::IP will accept short forms 1.1 and hostnames
        # so check if all 4 octets are defined
        return 4 unless ( $addr !~ /\d+\.\d+\.\d+\.\d+/ );    # undef
    } elsif ( $vers == 6 ) {
        return 6;
    }

    return;
}

sub is_link_local {
    my $ip = new NetAddr::IP( $_[0] );
    return unless $ip;

    my $link_local_net;
    if ( $ip->version() == 4 ) {
        $link_local_net = new NetAddr::IP('169.254.0.0/16');
    } else {
        $link_local_net = new NetAddr::IP('fe80::/10');
    }
    return $ip->within($link_local_net);
}

sub is_addr_multicast {
    my $ip = new NetAddr::IP $_[0];
    return unless $ip;

    # just the address
    $ip = NetAddr::IP->new( $ip->addr() );

    my $multicast_addr =
      $ip->version() == 4
      ? NetAddr::IP->new('224/4')
      : NetAddr::IP->new6('FF00::/8');

    return $ip->within($multicast_addr);
}

sub is_addr_loopback {
    my $this = new NetAddr::IP $_[0];
    my $loop =
      $this->version() == 4
      ? NetAddr::IP->new('loopback')
      : NetAddr::IP->new6('loopback');
    return $this->addr() eq $loop->addr();
}

sub isIpAddress {
    my $ip = shift;

    return unless $ip =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/;

    return unless ( $1 > 0  && $1 < 256 );
    return unless ( $2 >= 0 && $2 < 256 );
    return unless ( $3 >= 0 && $3 < 256 );
    return unless ( $4 >= 0 && $4 < 256 );
    return 1;
}

sub isClusterIP {
    my ( $vc, $ip ) = @_;

    return unless $ip;    # undef

    my @cluster_groups = $vc->listNodes('cluster group');
    foreach my $cluster_group (@cluster_groups) {
        my @services =
          $vc->returnValues("cluster group $cluster_group service");
        foreach my $service (@services) {
            if ( $service =~ /\// ) {
                $service = substr( $service, 0, index( $service, '/' ) );
            }
            if ( $ip eq $service ) {
                return 1;
            }
        }
    }

    return;
}

sub remove_ip_prefix {
    my @addr_nets = @_;

    s/\/\d+$// for @addr_nets;
    return @addr_nets;
}

sub is_ip_in_list {
    my ( $ip, @list ) = @_;

    @list = remove_ip_prefix(@list);
    my %list_hash = map { $_ => 1 } @list;

    return $list_hash{$ip};
}

sub isIPinInterfaces {
    my ( $vc, $ip_addr, @interfaces ) = @_;

    return unless $ip_addr;    # undef == false

    foreach my $name (@interfaces) {
        return 1 if ( is_ip_in_list( $ip_addr, getIP($name) ) );
    }

    return;                    # false (undef)
}

sub isClusteringEnabled {
    my ($vc) = @_;

    return $vc->exists('cluster');
}

# $str: string representing a port number
# returns ($success, $err)
# $success: 1 if success. otherwise undef
# $err: error message if failure. otherwise undef
sub isValidPortNumber {
    my $str = shift;
    return ( undef, "\"$str\" is not a valid port number" )
      if ( !( $str =~ /^\d+$/ ) );
    return ( undef, "invalid port \"$str\" (must be between 1 and 65535)" )
      if ( $str < 1 || $str > 65535 );
    return ( 1, undef );
}

# $str: string representing a port range
# $sep: separator for range
# returns ($success, $err)
# $success: 1 if success. otherwise undef
# $err: error message if failure. otherwise undef
sub isValidPortRange {
    my $str = shift;
    my $sep = shift;
    return ( undef, "\"$str\" is not a valid port range" )
      if ( !( $str =~ /^(\d+)$sep(\d+)$/ ) );
    my ( $start, $end ) = ( $1, $2 );
    my ( $success, $err ) = isValidPortNumber($start);
    return ( undef, $err ) if ( !defined($success) );
    ( $success, $err ) = isValidPortNumber($end);
    return ( undef, $err ) if ( !defined($success) );
    return ( undef, "invalid port range ($end is not greater than $start)" )
      if ( $end <= $start );
    return ( 1, undef );
}

# $str: string representing a port name
# $proto: protocol to check
# returns ($success, $err)
# $success: 1 if success. otherwise undef
# $err: error message if failure. otherwise undef
sub isValidPortName {
    my $str   = shift;
    my $proto = shift;
    return ( undef, "\"\" is not a valid port name for protocol \"$proto\"" )
      if ( $str eq '' );

    my $port = getservbyname( $str, $proto );
    return ( 1, undef ) if $port;

    return ( undef,
        "\"$str\" is not a valid port name for protocol \"$proto\"" );
}

sub getPortRuleString {
    my $port_str     = shift;
    my $can_use_port = shift;
    my $prefix       = shift;
    my $proto        = shift;
    my $negate       = '';
    if ( $port_str =~ /^!(.*)$/ ) {
        $port_str = $1;
        $negate   = '! ';
    }
    $port_str =~ s/(\d+)-(\d+)/$1:$2/g;

    my $num_ports = 0;
    my @port_specs = split /,/, $port_str;
    foreach my $port_spec (@port_specs) {
        my ( $success, $err ) = ( undef, undef );
        if ( $port_spec =~ /:/ ) {
            ( $success, $err ) = isValidPortRange( $port_spec, ':' );
            if ( defined($success) ) {
                $num_ports += 2;
                next;
            } else {
                return ( undef, $err );
            }
        }
        if ( $port_spec =~ /^\d/ ) {
            ( $success, $err ) = isValidPortNumber($port_spec);
            if ( defined($success) ) {
                $num_ports += 1;
                next;
            } else {
                return ( undef, $err );
            }
        }
        if ( $proto eq 'tcp_udp' ) {
            ( $success, $err ) = isValidPortName( $port_spec, 'tcp' );
            if ( defined $success ) {

                # only do udp test if the tcp test was a success
                ( $success, $err ) = isValidPortName( $port_spec, 'udp' );
            }
        } else {
            ( $success, $err ) = isValidPortName( $port_spec, $proto );
        }
        if ( defined($success) ) {
            $num_ports += 1;
            next;
        } else {
            return ( undef, $err );
        }
    }

    my $rule_str = '';
    if ( ( $num_ports > 0 ) && ( !$can_use_port ) ) {
        return ( undef,
                "ports can only be specified when protocol is \"tcp\" "
              . "or \"udp\" (currently \"$proto\")" );
    }
    if ( $num_ports > 15 ) {
        return ( undef,
                "source/destination port specification only supports "
              . "up to 15 ports (port range counts as 2)" );
    }
    if ( $num_ports > 1 ) {
        $rule_str = " -m multiport $negate --${prefix}ports ${port_str}";
    } elsif ( $num_ports > 0 ) {
        $rule_str = " $negate --${prefix}port ${port_str}";
    }

    return ( $rule_str, undef );
}

sub interface_description {
    my $name = shift;

    open my $ifalias, '<', "/sys/class/net/$name/ifalias"
      or return;

    my $description = <$ifalias>;
    close $ifalias;
    chomp $description if $description;

    if ( $description && ( $name =~ /ppp*/ ) ) {
        my ( $user, $proto, $dev, $rip, $pid ) = split( /\|/, $description );
        $description = "$proto $user $rip";

    }

    return $description;
}

# return only terminal width
sub get_terminal_width {
    my ( $rows, $cols ) = Vyatta::ioctl::get_terminal_size;
    return $cols;
}

# return only terminal height
sub get_terminal_height {
    my ( $rows, $cols ) = Vyatta::ioctl::get_terminal_size;
    return $rows;
}

sub valid_ipv6_addr {
    my $addr = shift;

    my $v6addr = Socket::inet_pton( AF_INET6, $addr );
    return ( defined $v6addr ) ? 1 : 0;
}

sub valid_ip_addr {
    my $addr = shift;

    my $ipaddr = Socket::inet_pton( AF_INET, $addr );
    return ( defined $ipaddr ) ? 1 : 0;
}

sub valid_ipv6_prefix {
    my $prefix = shift;

    my ( $addr, $prefixlen ) = split( /\//, $prefix );
    return (0) unless defined($addr);
    return (0) unless defined($prefixlen);
    return (0) unless ( $prefixlen >= 0 && $prefixlen <= 128 );
    return ( valid_ipv6_addr($addr) );
}

sub valid_ip_prefix {
    my $prefix = shift;

    my ( $addr, $prefixlen ) = split( /\//, $prefix );
    return (0) unless defined($addr);
    return (0) unless defined($prefixlen);
    return (0) unless ( $prefixlen >= 0 && $prefixlen <= 32 );
    return ( valid_ip_addr($addr) );
}

1;
