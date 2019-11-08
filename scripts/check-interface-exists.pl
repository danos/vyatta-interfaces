#! /usr/bin/perl
# **** License ****
# Copyright (c) 2018, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Interface;

my $intf = $ARGV[0];
my @cfgifs = map { $_->{name} } Vyatta::Interface::get_interfaces();
my $matches = grep { $_ eq $intf } @cfgifs;

print "Warning: interface $intf does not exist on this system\n"
    unless $matches > 0;
