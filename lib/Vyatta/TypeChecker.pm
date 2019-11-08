# Author: An-Cheng Huang <ancheng@vyatta.com>
# Date: 2007
# Description: Type checking script

# **** License ****
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
# **** End License ****

# Perl module for type validation.
# Usage 1: validate a value of a specific type.
#   use Vyatta::TypeChecker;
#   ...
#   if (validateType('ipv4', '1.1.1.1')) {
#     # valid
#     ...
#   } else {
#     # not valie
#     ...
#   }
#
# Usage 2: find the type of a value (from a list of candidates), returns
# undef if the value is not valid for any of the candidates.
#   $valtype = findType('1.1.1.1', 'ipv4', 'ipv6');
#   if (!defined($valtype)) {
#     # neither ipv4 nor ipv6
#     ...
#   } else {
#     if ($valtype eq 'ipv4') {
#       ...
#     } else {
#       ...
#     }
#   }

package Vyatta::TypeChecker;
use strict;

our @EXPORT = qw(findType validateType);
use base qw(Exporter);

my %type_handler = (
                    'ipv4' => \&validate_ipv4,
                    'ipv4net' => \&validate_ipv4net,
                    'ipv4range' => \&validate_ipv4range,
                    'ipv4_negate' => \&validate_ipv4_negate,
                    'ipv4net_negate' => \&validate_ipv4net_negate,
                    'ipv4range_negate' => \&validate_ipv4range_negate,
                    'iptables4_addr' => \&validate_iptables4_addr,
                    'protocol' => \&validate_protocol,
                    'protocol_negate' => \&validate_protocol_negate,
                    'macaddr' => \&validate_macaddr,
                    'macaddr_negate' => \&validate_macaddr_negate,
                    'ipv6' => \&validate_ipv6,
		    'ipv6_negate' => \&validate_ipv6_negate,
		    'ipv6net' => \&validate_ipv6net,
		    'ipv6net_negate' => \&validate_ipv6net_negate,
		    'hex16' => \&validate_hex_16_bits,
		    'hex32' => \&validate_hex_32_bits,
                    'ipv6_addr_param' => \&validate_ipv6_addr_param,
                    'restrictive_filename' => \&validate_restrictive_filename,
                    'no_bash_special' => \&validate_no_bash_special,
                    'u32' => \&validate_u32,
                    'bool' => \&validate_bool
                   );

sub validate_ipv4 {
  $_ = shift;
  return 0 if (!/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  return 0 if ($1 > 255 || $2 > 255 || $3 > 255 || $4 > 255);
  return 1;
}

sub validate_u32 {
  my $val = shift;
  return ($val =~ /^\d+$/ and $val < 2**32);
}

sub validate_bool {
  my $val = shift;
  return ($val eq 'true' or $val eq 'false');
}

sub validate_ipv4net {
  $_ = shift;
  return 0 if (!/^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/);
  return 0 if ($1 > 255 || $2 > 255 || $3 > 255 || $4 > 255 || $5 > 32);
  return 1;
}

sub validate_ipv4range {
  $_ = shift;
  return 0 if (!/^([^-]+)-([^-]+)$/);
  my ($a1, $a2) = ($1, $2);
  return 0 if (!validate_ipv4($a1) || !validate_ipv4($a2));
  #need to check that range is in ascending order
  $a1 =~ m/^(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)/;
  my $v1 = $1*256*256*256+$2*256*256+$3*256+$4;
  $a2 =~ m/^(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)/;
  my $v2 = $1*256*256*256+$2*256*256+$3*256+$4;
  return 0 if ($v1 > $v2);
  return 1;
}

sub validate_ipv4_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_ipv4($value);
}

sub validate_ipv4net_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_ipv4net($value);
}

sub validate_ipv4range_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_ipv4range($value);
}

sub validate_iptables4_addr {
  my $value = shift;
  return 0 if (!validate_ipv4_negate($value)
               && !validate_ipv4net_negate($value)
               && !validate_ipv4range_negate($value));
  return 1;
}

sub validate_protocol {
  my $value = shift;
  $value = lc $value;
  return 1 if ($value eq 'all');

  if ($value =~ /^\d+$/) {
      # 0 has special meaning to iptables
      return 1 if $value >= 1 and $value <= 255;
  }

  return defined getprotobyname($value);
}

sub validate_protocol_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_protocol($value);
}

sub validate_macaddr {
  my $value = shift;
  $value = lc $value;
  my $byte = '[0-9a-f]{2}';
  return 1 if ($value =~ /^$byte(:$byte){5}$/);
}

sub validate_macaddr_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_macaddr($value);
}

# IPv6 syntax definition
my $RE_IPV4_BYTE = '((25[0-5])|(2[0-4][0-9])|([01][0-9][0-9])|([0-9]{1,2}))';
my $RE_IPV4 = "$RE_IPV4_BYTE(\.$RE_IPV4_BYTE){3}";
my $RE_H16 = '([a-fA-F0-9]{1,4})';
my $RE_H16_COLON = "($RE_H16:)";
my $RE_LS32 = "(($RE_H16:$RE_H16)|($RE_IPV4))";
my $RE_IPV6_P1 = "($RE_H16_COLON)\{6\}$RE_LS32";
my $RE_IPV6_P2 = "::($RE_H16_COLON)\{5\}$RE_LS32";
my $RE_IPV6_P3 = "($RE_H16)?::($RE_H16_COLON)\{4\}$RE_LS32";
my $RE_IPV6_P4 = "(($RE_H16_COLON)\{0,1\}$RE_H16)?"
                 . "::($RE_H16_COLON)\{3\}$RE_LS32";
my $RE_IPV6_P5 = "(($RE_H16_COLON)\{0,2\}$RE_H16)?"
                 . "::($RE_H16_COLON)\{2\}$RE_LS32";
my $RE_IPV6_P6 = "(($RE_H16_COLON)\{0,3\}$RE_H16)?"
                 . "::($RE_H16_COLON)\{1\}$RE_LS32";
my $RE_IPV6_P7 = "(($RE_H16_COLON)\{0,4\}$RE_H16)?::$RE_LS32";
my $RE_IPV6_P8 = "(($RE_H16_COLON)\{0,5\}$RE_H16)?::$RE_H16";
my $RE_IPV6_P9 = "(($RE_H16_COLON)\{0,6\}$RE_H16)?::";
my $RE_IPV6 = "($RE_IPV6_P1)|($RE_IPV6_P2)|($RE_IPV6_P3)|($RE_IPV6_P4)"
               . "|($RE_IPV6_P5)|($RE_IPV6_P6)|($RE_IPV6_P7)|($RE_IPV6_P8)"
               . "|($RE_IPV6_P9)";

sub validate_ipv6 {
  $_ = shift;
  return 0 if (!/^$RE_IPV6$/);
  return 1;
}

sub validate_ipv6_negate {
  my $value = shift;
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_ipv6($value);
}

sub validate_ipv6net {
  my $value = shift;

  if ($value =~ m/^(.*)\/(.*)$/) {
    my $ipv6_addr = $1;
    my $prefix_length = $2;
    if ($prefix_length < 0 || $prefix_length > 128) {
      return 0;
    }
    return validate_ipv6($ipv6_addr);

  } else {
    return 0;
  }
}

sub validate_ipv6net_negate {
  my $value = shift;

  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }
  return validate_ipv6net($value);
}

# Validate a 16-bit hex value, no leading "0x"
sub validate_hex_16_bits {
  my $value = shift;
  $value = lc $value;
  return 1 if ($value =~ /^[0-9a-f]{4}$/)
}

# Validate a 32-bit hex value, no leading "0x"
sub validate_hex_32_bits {
  my $value = shift;
  $value = lc $value;
  return 1 if ($value =~ /^[0-9a-f]{8}$/)
}

# Validate the overloaded IPv6 source and destination address parameter in
# the firewall configuration tree.
sub validate_ipv6_addr_param {
  my $value = shift;

  # leading exclamation point is valid in all three formats
  if ($value =~ m/^\!(.*)$/) {
    $value = $1;
  }

  if ($value =~ m/^(.*)-(.*)$/) {
    # first format: <ipv6addr>-<ipv6-addr>
    if (validate_ipv6($1)) {
      return validate_ipv6($2);
    } else {
      return 0;
    }
  }

  elsif ($value =~ m/^(.*)\/(.*)$/) {
    # Second format:  <ipv6addr>/<prefix-len>
    return validate_ipv6net($value);
  }

  else {
    # third format:  <ipv6addr>
    return validate_ipv6($value)
  }
}

# validate a restrictive filename
sub validate_restrictive_filename {
  my $value = shift;
  return (($value =~ /^[-_.a-zA-Z0-9]+$/) ? 1 : 0);
}

# validate that a string does not contain bash special chars
sub validate_no_bash_special {
  my $value = shift;
  return (($value =~ /[;&"'`!\$><|]/) ? 0 : 1);
}

sub validateType {
  my ($type, $value, $quiet) = @_;
  if (!defined($type) || !defined($value)) {
    return 0;
  }
  if (!defined($type_handler{$type})) {
    print "type \"$type\" not defined\n" if (!defined($quiet));
    return 0;
  }
  if (!&{$type_handler{$type}}($value)) {
    print "\"$value\" is not a valid value of type \"$type\"\n"
      if (!defined($quiet));
    return 0;
  }

  return 1;
}

sub findType {
  my ($value, @candidates) = @_;
  return if (!defined($value) || ((scalar @candidates) < 1)); # undef

  foreach my $type (@candidates) {
    if (!defined($type_handler{$type})) {
      next;
    }
    if (&{$type_handler{$type}}($value)) {
      # the first valid type is returned
      return $type;
    }
  }
}

1;

# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 2
# End:
