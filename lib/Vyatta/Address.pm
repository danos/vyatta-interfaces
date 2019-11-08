# Module: Address.pm
# Description: IP address utilities

# Copyright (c) 2018 AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::Address;

use strict;
use warnings;

use File::Slurp;
use List::Util qw(any none);

# Test if address is IPv4
sub is_ipv4 {
    return index( $_[0], ':' ) < 0;
}

# Test if address is IPv6
sub is_ipv6 {
    return index( $_[0], ':' ) >= 0;
}

# Return IPv6 DAD config for a given interface
sub ipv6_dad_config {
    my $name       = shift;
    my $accept_dad = 0;       # Disable DAD by default
    my $retrans_sec = 1;  # Retrans timer always set to default 1s in controller
    my $dad_transmits = 1;
    my @dad_data = ( \$accept_dad, \$retrans_sec, \$dad_transmits );

    return @dad_data unless -d "/proc/sys/net/ipv6/conf/$name";

    # Check if DAD is enabled
    my $f = read_file( "/proc/sys/net/ipv6/conf/$name/accept_dad",
        err_mode => 'quiet' );
    return @dad_data unless defined($f);
    chomp($f);
    return @dad_data unless $f > 0;    # Return 0 if -ve number found
    $accept_dad = $f;

    # Number of DAD transmits
    $f = read_file( "/proc/sys/net/ipv6/conf/$name/dad_transmits",
        err_mode => 'quiet' );
    return @dad_data unless defined($f);
    chomp( $dad_transmits = $f );

    return @dad_data;
}

# Wait for DAD to complete for a tentative IPv6 global address
sub ipv6_tentative_addr_dad_wait {
    my ( $ifname, $addr ) = @_;

    # Retrieve DAD config for the interface the tentative address is on
    my ( $dad_on, $retry_sec, $retry_n ) = ipv6_dad_config($ifname);
    return unless $$dad_on;
    sleep $$retry_sec;

    # If the address is still tentative, wait for it to be assigned
    for ( my $retries = 0 ; $retries < $$retry_n ; $retries++ ) {
        my $addr_output = qx(ip -6 addr show to $addr);
        return if $addr_output !~ /tentative/;
        sleep $$retry_sec;
    }

    return;
}

# Get interface and its link state for an IPv4 or IPv6 address
sub get_interface {
    my $addr         = shift;
    my $if_name      = '';
    my $link_up      = 0;
    my $ip_tentative = 0;
    my @if_data      = ( \$if_name, \$link_up, \$ip_tentative );

    my @if_line = split( ' ', qx(ip addr show to $addr) );
    return @if_data unless @if_line;

    $if_name = $if_line[1];

    # Remove trailing ':'
    chop($if_name);

    # Nothing further to check if link is not up or no IPv6 address
    $link_up = 1 if ( any { /UP/ } @if_line );
    return @if_data unless ( $link_up && is_ipv6($addr) );

    # Check whether IPv6 address is tentative i.e. has not yet been assigned
    $ip_tentative = 1 if ( any { /tentative/ } @if_line );

    return @if_data;
}

# Wait for DAD to complete for a given IPv6 address
# Do not use this if interface is known, so as to avoid unnecesary system call
sub ipv6_global_addr_dad_wait {
    my $addr = shift;

    my ( $if_name, $link_up, $ip_tentative ) = get_interface($addr);
    if ( $$link_up && $$ip_tentative ) {
        ipv6_tentative_addr_dad_wait( $$if_name, $addr );
    }

    return;
}

# return true if addresses are overlapped.
sub is_address_overlapped_ip {
    my ( $ip1, $ip2 ) = map { new NetAddr::IP $_; } @_;
    my $sw = {
        -1 => sub { return 1 if $_[0]->contains( $_[1] ); },
        0  => sub { return 1 if $_[0]->network() eq $_[1]->network(); },
        1  => sub { return 1 if $_[0]->within( $_[1] ); }
    };

    return $sw->{ $ip1->masklen() <=> $ip2->masklen() }->( $ip1, $ip2 );
}

sub is_address_overlapped {
    my ( $addr_rt1, $addr_rt2 ) = @_;
    my @a1 = split( /,/, $addr_rt1 );
    my @a2 = split( /,/, $addr_rt2 );

    return if scalar(@a1) != scalar(@a2);    # 1 in default 2 in vrf
    return if ( scalar(@a1) == 2 and ( $a1[1] ne $a2[1] ) );   # not in same vrf
    return is_address_overlapped_ip( $a1[0], $a2[0] );
}

sub get_intervrf_nexthops {
    my ( $config, $route, $map ) = @_;
    my $path = "$route next-hop-routing-instance";
    for my $rd ( $config->listNodes($path) ) {
        for my $nexth ( $config->listNodes("$path $rd next-hop") ) {
            my $nha = NetAddr::IP->new($nexth);
            my $k   = $nha->addr;
            $k .= ",$rd" if ( $rd and $rd ne 'default' );
            $map->{$k} = "$route -> $nexth,$rd";
        }
    }
    return;    #undef
}

#
# Ensure that an interface address does not match any configured static
# next-hop address(es) (IPv4 or IPv6).
# generates a function closure that contains the needed state to check next-hops
# this avoids needing to rewalk the next-hops for each interface address.
sub gen_check_nexthop {
    return unless eval 'use Vyatta::Config; 1';

    my $config      = new Vyatta::Config();
    my $getnexthops = sub {
        my ($path) = @_;
        my $map = {};
        $config->setLevel("protocols static $path");
        for my $route ( $config->listNodes() ) {
            for my $nexth ( $config->listNodes("$route next-hop") ) {
                my $nha = NetAddr::IP->new($nexth);
                $map->{ $nha->addr } = "$route -> $nexth";
            }
            get_intervrf_nexthops( $config, $route, $map );
        }
        $config->setLevel("routing routing-instance");
        my @rds = $config->listNodes();
        for my $rd (@rds) {
            $config->setLevel(
                "routing routing-instance $rd protocols static $path");
            for my $route ( $config->listNodes() ) {
                for my $nexth ( $config->listNodes("$route next-hop") ) {
                    my $nha = NetAddr::IP->new($nexth);
                    $map->{ $nha->addr . ",$rd" } = "$route -> $nexth";
                }
                get_intervrf_nexthops( $config, $route, $map );
            }
        }
        return $map;
    };
    my $nhmaps = {
        "ipv4" => $getnexthops->("route"),
        "ipv6" => $getnexthops->("route6"),
    };
    return sub {
        my $addr = shift;
        my $map  = $nhmaps->{"ipv4"};
        $map = $nhmaps->{"ipv6"} unless is_ipv4($addr);
        my $nexth = $map->{$addr};
        return "" unless defined($nexth);
        my ( $a, $rt ) = split( /,/, $addr );
        my $msg = "Interface address $a matches next-hop address ( $nexth )\n";
        if ( defined($rt) ) {
			return "Rt Instance $rt: $msg\n";
		}
		return "$msg\n";
    };
}

sub dedup {
    my $aref = shift;
    my %seen;
    return grep { !$seen{$_}++ } @$aref;
}

sub err_dup_addr {
    my ( $art, $intfs ) = @_;
    my ( $a, $rt ) = split( /,/, $art );
    my @ifs = dedup($intfs);
    my $s   = ( scalar(@ifs) > 1 ) ? 's' : '';
    my $msg = join( ' ',
        "Duplicate address ${a} used on interface$s",
        join( ',', @ifs ) );
	if ( defined($rt) ) {
		return "Rt Instance $rt: $msg\n";
	}
	return "$msg\n";
}

sub err_same_subnet {
    my ( $prt, $intfs ) = @_;
    my ( $p, $rt ) = split( /,/, $prt );
    my $msg = join( ' ', "Same subnet $p in ", join( ',', @$intfs ) ) . "\n";
	if ( defined($rt) ) {
		return "Rt Instance $rt: $msg\n";
	}
	return "$msg\n";
}

sub err_overlapped_address {
    my ( $art, $details ) = @_;
    my ( $a, $rt ) = split( /,/, $art );
    my $msg = join( ' ', "Overlapped subnets $details" );
	if ( defined($rt) ) {
		return "Rt Instance $rt: $msg\n";
	}
	return "$msg\n";
}

# Validate the set of address values configured on all interfaces at commit
# Check that full set of address address values are consistent.
#  1. IP address cannot exist on any other interface
#  2. No overlapped subnets. But allow same subnets on a single if.
#  3. Ensure address is not a static route next-hop address
#
# NB: we don't die if we find an error, as it is preferable to find all
#     errors on the first pass.  However, if we get two identically worded
#     errors we suppress the second / subsequent one.  This can happen when
#     looking for duplicate addresses for example.
#
sub validate_all_addrs {
	return 1 unless eval 'use Vyatta::Interface; 1';

    my ( $addrmap, $prefixmap ) = Vyatta::Interface::get_cfg_addrmap();
    my $check_nexthop = gen_check_nexthop();
	my $status = 0;
	my $errmsg = "";
	my @errors;

    foreach my $addr ( keys %{$addrmap} ) {
        next if ( index( $addr, 'dhcp' ) == 0 );

        my $intfs = $addrmap->{$addr};
		if ( $intfs && scalar( @{$intfs} ) > 1 ) {
			$errmsg = err_dup_addr( $addr, $intfs );
			if ( none {$_ eq $errmsg} @errors ) {
				push @errors, $errmsg;
			}
			$status = 1;
			next;
		}

        # Allow addresses from same subnet on the same interface.
        # reject any overlap prefixes or same subnet on multiple
        # interfaces.
        my @overlaps =
          grep { is_address_overlapped( $addr, $_ ); } ( keys %$prefixmap );

        my $d_fn = sub {
            my @s =
              map {
                my ( $s, ) = split( /,/, $_ );
                "$s(" . join( ',', dedup( $prefixmap->{$_} ) ) . ")"
              } @overlaps;
            return join( ', ', @s );
        };

        # No overlapped subnets
        my @ifs = dedup( $prefixmap->{ $overlaps[0] } );

		if ( scalar(@overlaps) > 1 ) {
			$errmsg = err_overlapped_address( $addr, $d_fn->() );
			if ( none {$_ eq $errmsg} @errors ) {
				push @errors, $errmsg;
			}
			$status = 1;
			next;
		}

        # same subnets - allow same subnet on same interface
		if ( scalar(@ifs) > 1 ) {
			$errmsg = err_same_subnet( $overlaps[0], \@ifs );
			if ( none {$_ eq $errmsg} @errors ) {
				push @errors, $errmsg;
			}
			$status = 1;
			next;
		}

        $errmsg = $check_nexthop->($addr);
		if ( $errmsg ne "" ) {
			if ( none {$_ eq $errmsg} @errors ) {
				push @errors, $errmsg;
			}
			$status = 1;
		}
    }

	foreach my $error (@errors) {
		print "$error";
	}

	return $status;
}

# get system interface on which the specified address is configured
sub get_system_interface {
    return unless eval 'use Vyatta::Config; 1';

    my ( $addr, $addr_type ) = @_;
    my $if_name     = undef;
    my $mtu         = 1500;
    my $mtu_default = 1;
    my @if_data     = ( \$if_name, \$mtu, \$mtu_default );

    my $config  = new Vyatta::Config();
    my @sys_ifs = $config->listNodes("interfaces system");
    foreach my $intf (@sys_ifs) {
        my @if_addrs = $config->returnValues("interfaces system $intf address");
        my @match = grep { $_ =~ /$addr/ } @if_addrs;
        if ( scalar @match > 0 ) {
            $if_name = $intf;
            $mtu_default =
              defined( $config->isDefault("interfaces system $intf mtu") );
            if ( !$mtu_default ) {
                $mtu = $config->returnValue("interfaces system $intf mtu");
            }
            last;
        }
    }

    die "No system interface found with $addr_type address $addr\n"
      unless defined($if_name);
    return @if_data;
}

1;
