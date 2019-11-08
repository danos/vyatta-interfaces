#! /usr/bin/perl

# Standalone test for Vyatta::Misc::isIPInterfaces
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;
use Vyatta::Misc;
use Vyatta::Interface;

my $vc;
my @interfaces = getInterfaces();
print "Interfaces: ", join(' ',@interfaces),"\n";

foreach my $lip (@ARGV) {
    print $lip, " is";
    if (Vyatta::Misc::isIPinInterfaces($vc, $lip, @interfaces)) {
	print " in\n";
    } else {
	print " not in\n";
    }
}

exit 0;
