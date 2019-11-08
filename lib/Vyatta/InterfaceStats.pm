# Module: Interface-Stats.pm
# Vyatta interface stats functions

# **** License ****
# Copyright (c) 2018, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
# **** End License ****

package Vyatta::InterfaceStats;

use strict;
use warnings;

use Vyatta::Misc;
use base 'Exporter';

our @EXPORT = qw(get_intf_stats get_intf_type get_clear_stats get_counter_val
                 run_clear_intf_stats);

my $clear_stats_dir  = '/var/run/vyatta';
my $clear_file_magic = 'XYZZYX';

use bigint;
sub get_intf_stats {
    my ($intf, @stat_vars) = @_;

    my %stats = ();
    foreach my $var ( @stat_vars ) {
        my $r = get_sysfs_value( $intf, "statistics/$var" );
        $stats{$var} = $r if defined $r;
    }
    return %stats;
}

sub get_intf_type {
    my ($intf, @type_vars) = @_;

    my %type = ();
    foreach my $var ( @type_vars ) {
        my $r = get_sysfs_value( $intf, $var );
        $type{$var} = $r if defined $r;
    }
    return %type;
}

sub get_intf_statsfile {
    my $intf = shift;

    return "$clear_stats_dir/$intf.stats";
}

sub get_clear_stats {
    my ($intf, @stat_vars) = @_;

    my %stats = ();
    foreach my $var ( @stat_vars ) {
        $stats{$var} = 0;
    }

    my $filename = get_intf_statsfile($intf);

    open( my $f, '<', $filename )
      or return %stats;

    my $magic = <$f>;
    chomp $magic;
    if ( $magic ne $clear_file_magic ) {
        print "bad magic [$intf]\n";
        return %stats;
    }

    my $timestamp = <$f>;
    chomp $timestamp;
    $stats{'timestamp'} = $timestamp;

    while (<$f>) {
        chop;
        my ( $var, $val ) = split(/,/);
        $stats{$var} = $val;
    }
    close($f);
    return %stats;
}

# get_counter_all subtracts the value recorded at last clear from the
# counter. The code needs to deal with the wrapping of 32 or 64 bit counters.
# For 64 bits counters, it would take about 4 years 8 month to
# overflow a byte counter with traffic at 1 TBits/Second. Lets hope we all
# get 128 get bit counters by the time we reach 1 TBits/Second.
# But counters in some interfaces - like the ones in Marvell switches wraps
# at 32 bits. Provide a crude way of dealing with a wrapped 32 bit counter.
# The calculation in the else part is wrong if the counter wrapped around more
# than once after last clear.
# "$clear >> 32 != 0' is or-ed for
# completeness not likely to be evaluated in real life.
sub get_counter_val {
    my ( $clear, $now ) = @_;

    # no clear - return the current counter
    return $now if $clear == 0;

    # no wrap around return delta
    return $now - $clear unless ( $clear > $now );

    # counter wrapped - heuristic to identify a 32 bit counter
    my $mask = ( ( $clear >> 32 ) != 0 ) ? '0xFFFFFFFFFFFFFFFF' : '0xFFFFFFFF';
    my $value = ( $now - $clear ) & hex($mask);

    return $value;
}

sub run_clear_intf_stats {
    my ($intfs_ref, $stat_vars_ref) = @_;
    my @intfs = @{ $intfs_ref };
    my @stat_vars = @{ $stat_vars_ref };

    foreach my $intf (@intfs) {
        my %stats    = get_intf_stats($intf, @stat_vars);
        my $filename = get_intf_statsfile($intf);

        mkdir $clear_stats_dir unless ( -d $clear_stats_dir );

        open( my $f, '>', $filename )
          or die "Couldn't open $filename [$!]\n";

        print "Clearing $intf\n";
        print $f $clear_file_magic, "\n", time(), "\n";

        while ( my ( $var, $val ) = each(%stats) ) {
            print $f $var, ",", $val, "\n";
        }

        close($f);
    }
}

1;
