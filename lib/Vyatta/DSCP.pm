# Module DSCP.pm
#
# Provide object wrapper for DSCP

# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2013-2015, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

use strict;
use warnings;

package Vyatta::DSCP;
require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(dscp_lookup dscp_range dscp_values);
our @EXPORT_OK = qw(str2dscp);

use POSIX qw(strtoul);

# Initialize DSCP map with pool 1 codepoints
# http://www.iana.org/assignments/dscp-registry/dscp-registry.xhtml
my %dsfield = (
    'default' => 0,
    'cs0'     => 0,
    'cs1'     => 8,
    'cs2'     => 16,
    'cs3'     => 24,
    'cs4'     => 32,
    'cs5'     => 40,
    'cs6'     => 48,
    'cs7'     => 56,
    'af11'    => 10,
    'af12'    => 12,
    'af13'    => 14,
    'af21'    => 18,
    'af22'    => 20,
    'af23'    => 22,
    'af31'    => 26,
    'af32'    => 28,
    'af33'    => 30,
    'af41'    => 34,
    'af42'    => 36,
    'af43'    => 38,
    'ef'      => 46,
    'va'      => 44,
);

# convert string or numeric
sub str2dscp {
    my $str = shift;

    # match number (decimal or hex)
    if ( $str =~ /^([0-9]+)|(0x[0-9a-fA-F]+)$/ ) {
        my ( $num, $unparsed ) = POSIX::strtoul($str);
        if ( $str eq '' || $unparsed != 0 ) {
            return;    # undef for non numeric input
        } elsif ( $num < 0 || $num >= 64 ) {
            return;    # out of range
        } else {
            return $num;
        }
    } else {
        return $dsfield{ lc $str };
    }
}

sub dscp_lookup {
    my $str = shift;
    return $dsfield{ lc $str };
}

# Split range into values
# Take input of form:
#   1,af11,0x3,5-11
# return
#  ( 1 af11 0x3 5 6 7 8 9 10 11 )
sub dscp_range {
    my $range = shift;
    my @ret;

    for ( split( /,/, $range ) ) {
        if (/^([^-]+)-(.+)$/) {
            my $begin = str2dscp($1);
            return unless defined($begin);    # invalid start
            my $end = str2dscp($2);
            return unless defined($end);      # invalid end

            return if ( $end < $begin );      # invalid range
            for my $i ( $begin .. $end ) {
                push @ret, $i;
            }
        } else {
            my $dscp = str2dscp($_);
            return unless defined($dscp);
            push @ret, $dscp;
        }
    }
    return @ret;
}

# Show all possible value
sub dscp_values {
    return keys %dsfield;
}

use overload
  '""'     => 'stringify',
  '0+'     => 'numify',
  fallback => 1;

# convert string (either numeric or named) to object
sub new {
    my ( $class, $str ) = @_;
    my $value = str2dscp($str);

    return unless defined($value);

    my $self = \$value;
    bless $self, $class;
    return $self;
}

# convert object to number
sub numify {
    my $self = shift;

    return $$self;
}

# convert object to string
sub stringify {
    my $self = shift;

    return sprintf '%#x', $$self;
}

1;
