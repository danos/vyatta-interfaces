#!/usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# 
# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use lib "/opt/vyatta/share/perl5";
use Vyatta::UnnumberedInterface;
use strict;
use warnings;
use Getopt::Long;

my $dev;
my $ipv6;
my $force;

sub usage {
	print "Usage: $0 --force --dev=<interface> [--ipv6]\n";
	exit 1;
}

GetOptions("dev=s" => \$dev,
           "force" => sub { $force = 1; },
           "ipv6" => sub { $ipv6 = 1; },
          ) or usage();

usage() unless defined($dev);

unnumbered_update($dev, $ipv6, $force);
