#!/usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
# 
# Copyright (c) 2014-2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Getopt::Long;
use Vyatta::UnnumberedInterface;

my $dev;

sub usage {
	print "Usage: $0 --dev=<interface>\n";
	exit 1;
}

GetOptions("dev=s" => \$dev) or usage();

usage() unless defined($dev);

unnumbered_update_donor($dev);
exit 0;
