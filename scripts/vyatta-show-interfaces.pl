#!/usr/bin/perl
#
# Module: vyatta-show-interfaces.pl
#
# **** License ****
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Author: Stig Thormodsrud
# Date: February 2008
# Description: Script to display interface information
#
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";

use Vyatta::Configd;
use Vyatta::Interface;
use Vyatta::Misc;
use Vyatta::InterfaceStats;
use Vyatta::Dataplane;
use Vyatta::DataplaneStats;
use Getopt::Long;
use IPC::Run3;
use POSIX;
use Time::Duration;
use Time::HiRes qw( clock_gettime CLOCK_REALTIME );
use Try::Tiny;
use NetAddr::IP;
use JSON qw( decode_json );

use strict;
use warnings;

# Conditionally use VrfManager.
# vrf related functions are used only if Vyatta::VrfManager is installed
my $has_vrf;

BEGIN {
    if ( eval { require Vyatta::VrfManager; 1 } ) {
        $has_vrf = 1;
    }
}

#
# valid actions
#
my %action_hash = (
    'allowed'        => \&run_allowed,
    'show'           => \&run_show_intf,
    'show-brief'     => \&run_show_intf_brief,
    'show-count'     => \&run_show_counters,
    'show-extensive' => \&run_show_intf_extensive,
    'show-system'    => \&run_show_intf_system_all,
    'show-system-up' => \&run_show_intf_system_up,
    'clear'          => \&run_clear_intf,
    'reset'          => \&run_reset_intf,
    'dhcp_allowed'   => \&run_dhcp_allowed,
);

# whether to print "Routing Instance" line
my %vrf_info_print = (
    'show-brief' => 1,
    'show-count' => 1,
);

my @rx_stat_vars =
  qw/rx_bytes rx_packets rx_errors rx_dropped rx_over_errors multicast/;
my @tx_stat_vars =
  qw/tx_bytes tx_packets tx_errors tx_dropped tx_carrier_errors collisions/;

# init_vrf_info : returns a closure for cached interface name to vrf query
# if $has_vrf is set - otherwire returns undefined.
sub init_vrf_info {
    return unless $has_vrf;
    my ($ifnames) = @_;
    my %intf_vrf_map =
      map { $_ => Vyatta::VrfManager::get_interface_vrf($_) } @$ifnames;
    return sub {
        my $name = shift;
        return $intf_vrf_map{$name};
    };
}

my $if2vrf_func;    # maps ifname2 a vrf name defined if $has_vrf is set

sub if2vrf {
    return unless defined($if2vrf_func);
    return $if2vrf_func->(@_);
}

sub match_ri {
    my ( $ifname, $rd ) = @_;
    my $ifrd = if2vrf($ifname);
    return ( defined($ifrd) and $ifrd eq $rd );
}

sub make_vrf_map {
    my ($ifnames) = @_;
    my %vrf_intf_map;

    for my $name (@$ifnames) {
        next if $name =~ m/^lord/;
        my $rd = if2vrf($name);
        next unless $rd;
        if ( exists( $vrf_intf_map{$rd} ) ) {
            push @{ $vrf_intf_map{$rd} }, $name;
        } else {
            $vrf_intf_map{$rd} = [$name];
        }
    }
    return \%vrf_intf_map;
}

sub get_intf_description {
    my $name        = shift;
    my $description = interface_description($name);

    return "" unless $description;
    return $description;
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

sub get_ipaddr {
    my $name = shift;

    # Skip local addresses and loopback on lo
    return grep { !ignore_addr( $name, $_ ) } Vyatta::Misc::getIP($name);
}

sub get_state_link {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);
    return unless $intf;

    my $state;
    my $link = 'down';

    if ( $intf->up() ) {
        $state = 'up';
        $link = "up" if ( $intf->running() );
    } else {
        $state = "admin down";
    }

    return ( $state, $link );
}

sub is_valid_intf {
    my $name = shift;
    return unless $name;

    my $intf = new Vyatta::Interface($name);
    return unless $intf;

    return $intf->exists();
}

sub get_intf_for_type {
    my $type       = shift;
    my @interfaces = getInterfaces();
    my @list       = ();
    foreach my $name (@interfaces) {
        if ($type) {
            my $intf = new Vyatta::Interface($name);
            next unless $intf;    # unknown type
            next if ( $type ne $intf->type() );
        }
        push @list, $name;
    }

    return @list;
}

# Find all vif interfaces
sub get_vif_intf {
    my @interfaces = getInterfaces();
    my @list       = ();

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf && defined( $intf->vif() );
        push @list, $name;
    }

    return @list;
}

# Find vif's of an interface
sub get_vif_of {
    my $parent = shift;

    my @interfaces = getInterfaces();
    my @list       = ();

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf && defined( $intf->vif() );
        next unless $intf->physicalDevice() eq $parent;

        push @list, $name;
    }

    return @list;
}

# Find vrrp interfaces
sub get_vrrp_intf {
    my @interfaces = getInterfaces();
    my @list       = ();

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf && defined( $intf->vrid() );
        push @list, $name;
    }

    return @list;
}

#
# The "action" routines
#

sub run_allowed {
    my $intfs = shift;
    print "@$intfs";
}

sub run_dhcp_allowed {
    my $intfs = shift;
    @$intfs = grep $_ !~ /^(tun|lo|erspan|vti|lttp|gre)/, @$intfs;
    print "@$intfs";
}

sub run_show_intf {
    my $intfs = shift;    # ignore nohdr

    foreach my $intf (@$intfs) {
        my $interface = new Vyatta::Interface($intf);

        # ignore tunnels, unknown interface types, etc.
        next unless $interface;

        my %clear = get_clear_stats( $intf, ( @rx_stat_vars, @tx_stat_vars ) );
        my $description = $interface->description();
        my $timestamp   = $clear{'timestamp'};

        my $prefix = Vyatta::Misc::VrfCmdPrefix($intf);
        my $ipcmd  = "${prefix}ip";

        my $line = `$ipcmd addr show $intf | sed 's/^[0-9]*: //'`;
        chomp $line;

        my $vrfname = if2vrf($intf);
        $line =~ s/rdid \d+/routing-instance $vrfname/ if defined $vrfname;

        if ( $line =~ /link\/tunnel6/ ) {
            my $estat = `$ipcmd -6 tun show $intf | sed 's/.*encap/encap/'`;
            $line =~ s%    link/tunnel6%    $estat$&%;
        }

        print "$line\n";

        my $transns = $interface->opstate_changes();
        if ($transns) {
            my $opstate = $interface->operstate();
            my $age     = $interface->opstate_age();
            print "   ";
            print " uptime: " . duration_exact($age)
              if ( $opstate eq 'up' );
            print " transitions: " . $transns;

            # use hires to avoid toggling the seconds value based on
            # how the fractions are trunctated by time() and then do
            # the rounding.
            my $ts = sprintf( "%.0f", clock_gettime(CLOCK_REALTIME) - $age );
            print " last-change: " . get_timestr($ts) . "\n";
        }

        if ( defined $timestamp and $timestamp ne "" ) {
            print "    Last clear: " . get_timestr($timestamp) . "\n";
        }
        if ( defined $description and $description ne "" ) {
            print "    Description: $description\n";
        }
        print "\n";
        my %stats = get_intf_stats( $intf, ( @rx_stat_vars, @tx_stat_vars ) );

        my $fmt = "    %10s %10s %10s %10s %10s %10s\n";

        printf( $fmt,
            "RX:  bytes", "packets", "errors",
            "ignored",    "overrun", "mcast" );
        printf( $fmt,
            map { get_counter_val( $clear{$_}, $stats{$_} ) } @rx_stat_vars );

        printf( $fmt,
            "TX:  bytes", "packets", "errors",
            "dropped",    "carrier", "collisions" );
        printf( $fmt,
            map { get_counter_val( $clear{$_}, $stats{$_} ) } @tx_stat_vars );
    }
}

sub show_intf_system {
    my $enabled_only = shift;

    my @cmd = ( "ip", "-s", "-d", "link", "show" );
    push( @cmd, "up" ) if ($enabled_only);

    my @lines;
    try {
        if ( !run3( \@cmd, undef, \@lines ) ) {
            return;
        }
    }
    catch {
        die("Failed to exec ip: $_");
    };

    my $ignore = "\.spathintf";
    my $skip   = 0;
    foreach my $line (@lines) {
        if ( $skip && $line =~ /^\s+/ ) {
            next;
        } elsif ( $line =~ /^[0-9]+:\s+($ignore):/ ) {
            $skip = 1;
            next;
        } else {
            $skip = 0;
        }

        print($line);
    }
}

sub run_show_intf_system_all {
    return show_intf_system(0);
}

sub run_show_intf_system_up {
    return show_intf_system(1);
}

sub conv_brief_code {
    my $state = pop(@_);
    $state = 'u' if ( $state eq 'up' );
    $state = 'D' if ( $state eq 'down' );
    $state = 'A' if ( $state eq 'admin down' );
    return $state;
}

sub conv_descriptions {
    my $description = pop @_;
    my @descriptions;
    my $term_width;
    $term_width = $ENV{'COLUMNS'}    if $ENV{'COLUMNS'};
    $term_width = get_terminal_width if not defined $term_width;
    $term_width = 80 if ( !defined($term_width) || $term_width == 0 );
    my $desc_len = $term_width - 69;
    my $line     = '';
    foreach my $elem ( split( ' ', $description ) ) {

        if ( ( length($line) + length($elem) ) >= $desc_len ) {
            push( @descriptions, $line );
            $line = "$elem ";
        } else {
            $line .= "$elem ";
        }
    }
    push( @descriptions, $line );
    return @descriptions;
}

sub human_readable_speed {
    my ($speed) = @_;
    my $units;
    my $divisor;

    if ( $speed == 0 ) {
        return "-";
    } elsif ( $speed < 1000 ) {
        $units   = "m";
        $divisor = 1;
    } else {
        $units   = "g";
        $divisor = 1000;
    }

    if ( ( $speed % $divisor ) != 0 ) {
        return sprintf "%.1f%s", $speed / $divisor, $units;
    } else {
        return sprintf "%d%s", $speed / $divisor, $units;
    }
}

sub run_show_intf_brief {
    my ( $intfs, $nohdr ) = @_;
    my $format  = "%-15s %-33s %-4s %-13s %s\n";
    my $format2 = "%-15s %s\n";

    unless ($nohdr) {
        print "Codes: S - State, L - Link, u - Up, D - Down, A - Admin Down\n";
        printf( $format,
            "Interface", "IP Address", "S/L", "Speed/Duplex", "Description" );
        printf( $format,
            "---------", "----------", "---", "------------", "-----------" );
    }

    my $config = Vyatta::Configd::Client->new();
    die "Unable to connect to the Vyatta Configuration Daemon"
      unless defined($config);

    my $oper_tree =
      $config->tree_get_full_hash( "interfaces statistics interface",
        { 'database' => $Vyatta::Configd::Client::RUNNING } );

    my $phys_tree;
    $phys_tree = $config->tree_get_hash( "interfaces dataplane",
        { 'database' => $Vyatta::Configd::Client::RUNNING } )
      if $config->node_exists( $Vyatta::Configd::Client::AUTO,
        "interfaces dataplane" );

    my %oper_state_map = (
        up   => 'u',
        down => 'D',
    );
    my %admin_state_map = (
        up   => 'u',
        down => 'A',
    );

    # Create a hash of known dataplane interfaces
    my @dataplane_intfs = get_intf_for_type("dataplane");
    my %dataplane_intfs = map { $_ => 1; } @dataplane_intfs;

    # Create a hash of dataplane interface configuration
    my %phys_tree = map { $_->{tagnode} => $_; } @{ $phys_tree->{'dataplane'} };

    my %i;
    @i{@$intfs} = ();
    foreach my $intf_oper ( @{ $oper_tree->{'interface'} } ) {
        my $intf = $intf_oper->{name};
        next unless exists $i{$intf};

        # Find the matching interface configuration
        my $intf_config = $phys_tree{$intf} if defined $phys_tree{$intf};

        # Convert descriptions to fit onto current terminal size
        #
        my $description = $intf_oper->{description};
        my @descriptions;
        @descriptions = conv_descriptions($description)
          if defined($description);

        # Determine link state from operational state
        #
        my $state = $admin_state_map{ $intf_oper->{'admin-status'} };
        my $link  = $oper_state_map{ $intf_oper->{'oper-status'} };

        my $config_speed;
        my $config_duplex;

        # If this is a dataplane interface, the default speed and
        # and duplex is auto/auto. We use get_tree_hash() above
        # for performance reason so we can't get the default
        # state for dataplane interfaces.
        #
        # If this is not a dataplane interface, report -/-
        # because speed and duplex on non-pysical interfaces
        # is meaningless.
        #
        if ( defined $dataplane_intfs{$intf} ) {
            $config_speed  = 'auto';
            $config_duplex = 'auto';
            if ( defined $intf_config ) {
                $config_speed = $intf_config->{speed}
                  if defined $intf_config->{speed};
                $config_duplex = $intf_config->{duplex}
                  if defined $intf_config->{duplex};
            }
        } else {
            $config_speed  = '-';
            $config_duplex = '-';
        }

        my $oper_speed  = 0;
        my $oper_duplex = '-';
        $oper_speed = $intf_oper->{speed} if defined $intf_oper->{speed};
        $oper_duplex = $intf_oper->{duplex}
          if defined $intf_oper->{duplex} and $intf_oper->{duplex} ne "unknown";

        # When link is up show the operational state. When link is
        # oper/admin down show the configured state.

        my $speed;
        my $duplex;
        if ( $state eq 'A' || $link eq 'D' ) {
            $speed  = $config_speed;
            $duplex = $config_duplex;
        } else {

            # Interface operational speeds are returned in bits/sec.
            $speed  = human_readable_speed($oper_speed);
            $duplex = $oper_duplex;

            # Corner: If the interface was configured for auto, prepend
            # operational state with a-
            #
            if ($intf_config) {
                $speed  = 'a-' . $speed  if $config_speed eq "auto";
                $duplex = 'a-' . $duplex if $config_duplex eq "auto";
            }
        }

        my @ip_addr;
        @ip_addr = @{ $intf_oper->{addresses} }
          if defined $intf_oper->{addresses};
        if ( scalar(@ip_addr) == 0 ) {
            next if ( $intf eq 'lo' );

            my $desc = '';
            $desc = shift @descriptions if ( scalar(@descriptions) > 0 );
            printf( $format,
                $intf, "-", "$state/$link", "$speed/$duplex", $desc );
            foreach my $descrip (@descriptions) {
                printf( $format, '', '', '', '', $descrip );
            }
        } else {
            my $tmpip = shift(@ip_addr);
            $tmpip = $tmpip->{'address'};
            my $desc = '';
            if ( length($tmpip) < 33 ) {
                $desc = shift @descriptions if ( scalar(@descriptions) > 0 );
                printf( $format,
                    $intf, $tmpip, "$state/$link", "$speed/$duplex", $desc );
                foreach my $descrip (@descriptions) {
                    printf( $format, '', '', '', '', $descrip );
                }
                foreach my $ip (@ip_addr) {
                    printf( $format2, '', $ip->{'address'} )
                      if ( defined $ip->{'address'} );
                }
            } else {
                $desc = shift @descriptions if ( scalar(@descriptions) > 0 );
                printf( $format2, $intf, $tmpip );
                my $printed_desc = 0;
                foreach my $ip (@ip_addr) {
                    if ( length( $ip->{'address'} ) >= 33 ) {
                        printf( $format2, '', $ip->{'address'} )
                          if ( defined $ip->{'address'} );
                    } else {
                        if ( !$printed_desc ) {
                            printf( $format,
                                '', $ip->{'address'}, "$state/$link",
                                "$speed/$duplex", $desc );
                            $printed_desc = 1;
                            foreach my $descrip (@descriptions) {
                                printf( $format, '', '', '', '', $descrip );
                            }
                        } else {
                            printf( $format2, '', $ip->{'address'} );
                        }
                    }
                }
                if ( !$printed_desc ) {
                    printf( $format,
                        '', '', "$state/$link", "$speed/$duplex", $desc );
                    foreach my $descrip (@descriptions) {
                        printf( $format, '', '', '', '', $descrip );
                    }
                }
            }
        }
    }
}

sub run_show_intf_extensive {
    my $intfs = shift;    # ignores nohdr

    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();
    my $response = vplane_exec_cmd( "ifconfig", $dpids, $dpsocks, 1 );
    my @results;

    # Decode the response from each vplane
    for my $dpid ( @{$dpids} ) {
        next unless defined( $response->[$dpid] );
        my $decoded = decode_json( $response->[$dpid] );
        $results[$dpid] = $decoded;
    }

    # Filter out any non-dataplane interfaces
    # With VDR each interface gets replicated to each vplane. Need to
    # find the ifconfig output associated with the actual physical
    # instance - matching dataplane IDs.
    #
    my @dpiflist;
    my %interfaces;
    foreach my $ifname (@$intfs) {
        my $intf = Vyatta::Interface->new($ifname);
        next unless ( defined($intf) && ( $intf->type() eq 'dataplane' ) );
        push @dpiflist, $ifname;
        my $dpid = $intf->dpid();
        next unless defined($dpid);
        foreach my $interface ( @{ $results[$dpid]->{'interfaces'} } ) {
            if ( $interface->{'name'} eq $ifname ) {
                $interfaces{$ifname} = $interface;
                last;
            }
        }
    }

    foreach my $intf (@dpiflist) {
        printf "%s:\n", $intf;

        next unless $interfaces{$intf};

        my $statistics  = $interfaces{$intf}->{'statistics'};
        my $xstatistics = $interfaces{$intf}->{'xstatistics'};

        my @keys = ( keys(%$statistics), keys(%$xstatistics) );
        my @sortedkeys = sort(@keys);

        @sortedkeys =
          show_keys( "^rx|^vf_rx", \@sortedkeys, $statistics, $xstatistics );
        @sortedkeys =
          show_keys( "^tx|^vf_tx", \@sortedkeys, $statistics, $xstatistics );
        #
        # Skip the list (array) of queue stats in the "statistics"
        # object. The xstatistics object includes the values for queue
        # element 0 (rx_q0_rx_packets, rx_q0_rx_bytes, ...)
        #
        show_keys( "(^?!qstats).", \@sortedkeys, $statistics, $xstatistics );
    }
}

# Show keys matching a regexp, returning the keys that didn't match
sub show_keys {
    my $regexp      = $_[0];
    my @keys        = @{ $_[1] };
    my $statistics  = $_[2];
    my $xstatistics = $_[3];
    my @remainingkeys;

    my $col     = 0;
    my $lastkey = '';

    foreach my $key (@keys) {
        my $value;

        next if ( $key eq $lastkey );
        if ( $key =~ /$regexp/ ) {
            if ( defined( $xstatistics->{$key} ) ) {
                $value = $xstatistics->{$key};
            } else {
                $value = $statistics->{$key};
            }
            show_key_value( $key, $value );

            $lastkey = $key;
            $col     = $col + 1;
            if ( $col % 2 == 0 ) {
                printf "\n";
            }
        } else {
            push( @remainingkeys, $key );
        }
    }
    if ( $col % 2 == 1 ) {
        printf "\n";
    }
    printf "\n";

    return @remainingkeys;
}

sub expand_array {
    my ( $readable, @array ) = @_;

    my $i;
    my $result = "";
    for ( $i = 0 ; $i < $#array + 1 ; ++$i ) {
        my $value;

        if ($readable) {
            $value = human_readable( $array[$i] );
        } else {
            $value = $array[$i];
        }
        $result = $result . sprintf "%s", $value;
        if ( $i < $#array ) {
            $result = $result . ", ";
        }
    }

    return $result;
}

sub show_key_value {
    my ( $key, $value ) = @_;
    my $ALIGN = 40;

    if ( ref($value) eq 'ARRAY' ) {

        # convert 1m, 5m, 15m averages to a human readable string
        if ( $key =~ /_avg$/ ) {
            $value = expand_array( 1, @{$value} );
        } else {
            $value = expand_array( 0, @{$value} );
        }
    }
    $key =~ s/_/ /g;
    my $offset = 0;

    # NOTE: comma is a separator here, not a sequence point
    printf "  %s: %n", $key, $offset;
    printf "%-*s", $ALIGN - $offset, $value;
}

sub run_show_counters {
    my ( $intfs, $nohdr ) = @_;
    my $format = "%-16s %10s %10s     %10s %10s\n";

    unless ($nohdr) {
        printf( $format,
            "Interface",
            "Rx Packets",
            "Rx Bytes",
            "Tx Packets",
            "Tx Bytes" );
    }

    foreach my $intf (@$intfs) {
        my ( $state, $link ) = get_state_link($intf);
        next unless defined($state);
        next if ( $state ne 'up' );

        my @stat_vars = ( @rx_stat_vars, @tx_stat_vars );
        my %clear = get_clear_stats( $intf, @stat_vars );
        my %stats = get_intf_stats( $intf, @stat_vars );

        printf( $format,
            $intf,
            get_counter_val( $clear{rx_packets}, $stats{rx_packets} ),
            get_counter_val( $clear{rx_bytes},   $stats{rx_bytes} ),
            get_counter_val( $clear{tx_packets}, $stats{tx_packets} ),
            get_counter_val( $clear{tx_bytes},   $stats{tx_bytes} ) );
    }
}

sub run_clear_intf {
    my $intfs = shift;
    my @stat_vars = ( @rx_stat_vars, @tx_stat_vars );

    run_clear_intf_stats( $intfs, \@stat_vars );

    my @dataplane_intfs = sort grep { /^dp\d/ } @$intfs;
    return unless scalar(@dataplane_intfs);
    clear_dataplane_interfaces( \@dataplane_intfs );
}

sub run_reset_intf {
    my $intfs = shift;

    foreach my $intf (@$intfs) {
        my $filename =
          get_intf_stats( $intf, ( @rx_stat_vars, @tx_stat_vars ) );
        system("rm -f $filename");
    }
}

sub alphanum_split {
    my ($str) = @_;
    my @list = split m/(?=(?<=\D)\d|(?<=\d)\D)/, $str;
    return @list;
}

sub natural_order {
    my ( $a, $b ) = @_;
    my @a = alphanum_split($a);
    my @b = alphanum_split($b);

    while ( @a && @b ) {
        my $a_seg = shift @a;
        my $b_seg = shift @b;
        my $val;
        if ( ( $a_seg =~ /\d/ ) && ( $b_seg =~ /\d/ ) ) {
            $val = $a_seg <=> $b_seg;
        } else {
            $val = $a_seg cmp $b_seg;
        }
        if ( $val != 0 ) {
            return $val;
        }
    }
    return @a <=> @b;
}

sub human_readable {
    my ($value) = @_;

    my @suffixes = ( "", "K", "M", "G", "T", "P" );

    my $index = 0;
    while ( $value > 1000.0 && $index < $#suffixes ) {
        $value = $value / 1000.0;
        ++$index;
    }

    return sprintf "%.3g%s", $value, $suffixes[$index];
}

sub intf_sort {
    my @a = @_;
    my @new_a = sort { natural_order( $a, $b ) } @a;
    return @new_a;
}

# routing instance related show functions..
sub print_vrf_lines {
    my $ri  = shift;
    my $str = "Routing Instance $ri";
    print "\n";
    print "$str\n";
    print "-" x length($str) . "\n";
}

sub check_vrf_exist {
    my ($ri) = @_;
    return ( $has_vrf
          && defined($Vyatta::VrfManager::VRFID_INVALID)
          && Vyatta::VrfManager::get_vrf_id($ri) !=
          $Vyatta::VrfManager::VRFID_INVALID );
}

sub run_actions_vrf {
    my ( $ifnames, $ri_arg, $action, $fn ) = (@_);

    # No special formats  for a specific vrf
    if ( $ri_arg ne 'all' ) {

        # single vrf - no looping
        my $iflist = [ grep { match_ri( $_, $ri_arg ) } @$ifnames ];
        die "Invalid Routing Instance $ri_arg\n"
          if ( scalar(@$iflist) == 0 && !check_vrf_exist($ri_arg) );
        $fn->($iflist);
        return;
    }

    # Always run actions for default first - then in alphabetical
    # order of routing instances.
    # use headers only for the first one
    my $h = make_vrf_map($ifnames);
    if ( defined( $h->{default} ) ) {
        $fn->( $h->{default} );
        delete $h->{default};
    } elsif ( defined( $vrf_info_print{$action} ) ) {
        $fn->( [] );    # print headers before Routing Instance lines
    }
    return unless scalar( keys %$h );
    my @ri_list = sort { $a cmp $b } ( keys %$h );
    for my $ri (@ri_list) {
        print_vrf_lines($ri) if ( defined( $vrf_info_print{$action} ) );
        $fn->( $h->{$ri}, 1 );
    }
}

sub usage {
    print "Usage: $0 [",
      join( '|',
        qw(intf=NAME intf-type=TYPE vif vrrp),
        $has_vrf ? ('--vrf=VRF') : () )
      . "] action=ACTION\n";

    print "  NAME = ", join( ' | ', get_intf_for_type() ), "\n";
    print "  TYPE = ", join( ' | ', Vyatta::Interface::interface_types() ),
      "\n";
    print "  ACTION = ", join( ' | ', keys %action_hash ), "\n";
    print "  VRF = ", join( ' | ', qw(default all <vrfname>) ), "\n"
      if $has_vrf;
    exit 1;
}

#
# main
#
my ( $intf_type, $intf, $intf_vif, $vif_only, $vrrp_only );
my $action = 'show';
my $vrf;

GetOptions(
    "intf-type=s" => \$intf_type,
    "intf-vif=s"  => \$intf_vif,
    "vif"         => \$vif_only,
    $has_vrf ? ( "vrf=s" => \$vrf ) : (),
    "vrrp"     => \$vrrp_only,
    "intf=s"   => \$intf,
    "action=s" => \$action,
) or usage();

my @intf_list;
if ($intf) {
    die "Invalid interface [$intf]\n"
      unless is_valid_intf($intf);

    push @intf_list, $intf;
} elsif ($intf_type) {
    @intf_list = get_intf_for_type($intf_type);
} elsif ($intf_vif) {
    @intf_list = get_vif_of($intf_vif);
} elsif ($vif_only) {
    @intf_list = get_vif_intf();
} elsif ($vrrp_only) {
    @intf_list = get_vrrp_intf();
} else {

    # get all interfaces (except the hidden ones)
    @intf_list =
      grep( !/^(\.spathintf|ip_vti\d+|lord\d+)$/, get_intf_for_type() );
}

@intf_list = intf_sort(@intf_list);

my $func;
if ( defined $action_hash{$action} ) {
    $func = $action_hash{$action};

    # special case for DHCPv4/v6 server/relay: only interfaces
    # belonging to default VRF could be involved in DHCPv4/v6
    # server/relay running in default vrf.
    if ( ( $action eq 'dhcp_allowed' ) and ($has_vrf) and ( !defined($vrf) ) ) {
        $vrf = 'default';
    }
} else {
    print "Invalid action [$action]\n";
    usage();
}

#
# make it so...
$if2vrf_func = init_vrf_info( \@intf_list );
unless ($vrf) {
    $func->( \@intf_list );
} else {
    run_actions_vrf( \@intf_list, $vrf, $action, $func );
}
