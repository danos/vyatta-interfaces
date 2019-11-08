# Module Rate.pm
#
# Copyright (c) 2013-2015, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#
# This package provides a method to parse data rates

package Vyatta::Rate;
use strict;
use warnings;

use Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(parse_rate
  parse_ppt);

# for now upper limit is limited by the 32 bit value bytes/second
# in current DPDK; therefore can not do > 25Gbit without API change.
use constant RATE_UNLIMITED => 25000000000;

## get_rate("10mbit")
# convert rate specification to number
# from tc/tc_util.c
my %rates = (
    'bit'   => 1,
    'kibit' => 1024,
    'kbit'  => 1000.,
    'mibit' => 1048576.,
    'mbit'  => 1000000.,
    'gibit' => 1073741824.,
    'gbit'  => 1000000000.,
    'tibit' => 1099511627776.,
    'tbit'  => 1000000000000.,
    'bps'   => 8.,
    'kibps' => 8192.,
    'kbps'  => 8000.,
    'mibps' => 8388608.,
    'mbps'  => 8000000.,
    'gibps' => 8589934592.,
    'gbps'  => 8000000000.,
    'tibps' => 8796093022208.,
    'tbps'  => 8000000000000.,
);

# Convert input to number and suffix
sub _get_num {
    use POSIX qw(strtod);
    my ($str) = @_;
    return unless defined($str);

    # remove leading/trailing spaces
    $str =~ s/^\s+//;
    $str =~ s/\s+$//;

    $! = 0;
    my ( $num, $unparsed ) = strtod($str);
    if ( ( $unparsed == length($str) ) || $! ) {
        return;    # undefined (bad input)
    }

    if ( $unparsed > 0 ) { return $num, substr( $str, -$unparsed ); }
    else                 { return $num; }
}

# Convert user input to bits/sec
sub parse_rate {
    my $rate = shift;

    die "bandwidth not defined\n"
      unless ( defined($rate) );

    return RATE_UNLIMITED
      if ( $rate eq 'unlimited' );

    my ( $num, $suffix ) = _get_num($rate);

    die "'$rate' is not a valid bandwidth\n"
      unless ( defined $num );

    die "Bandwidth of zero is not allowed\n"
      if ( $num == 0 );

    die "$rate can not be negative\n"
      if ( $num < 0 );

    # No suffix implies Kbps just as IOS
    return $num * 1000
      unless defined($suffix);

    my $scale = $rates{ lc $suffix };
    die "$rate is not a valid bandwidth (unknown scale suffix)\n"
      unless defined($scale);

    return $num * $scale;
}

# Now we have the packet rates

# for now upper limit is limited by the 32 bit signed atomic32 var
# so we'll restrict the max rate a 2G pps.
use constant PPS_RATE_UNLIMITED => 2000000000;

# convert rate specification to number
my %pkt_rates = (
   'pps'   => 1,
   'kpps'   => 1024,
   'mpps'   => 1000000,
);

# Convert user input to packets/sec from packet multiplier/sec
sub parse_ppt {
    my $rate = shift;

    die "packet rate not defined\n"
      unless ( defined($rate) );

    return PPS_RATE_UNLIMITED
      if ( $rate eq 'unlimited' );

    my ( $num, $suffix ) = _get_num($rate);

    die "'$rate' is not a valid packet rate\n"
      unless ( defined $num );

    die "Ratelimit of zero is not allowed\n"
      if ( $num == 0 );

    die "$rate can not be negative\n"
      if ( $num < 0 );

    # No suffix so return pps value
    return $num
      unless defined($suffix);

    my $scale = $pkt_rates{ lc $suffix };
    die "$rate is not a valid packet rate (unknown scale suffix)\n"
      unless defined($scale);

    my $pps_rate = $num * $scale;

    die "$pps_rate is above 2G max packet/sec rate\n"
      if ( $pps_rate > 2000000000 );

    return $pps_rate;
}

1;
