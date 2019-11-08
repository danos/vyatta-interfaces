#!/usr/bin/perl

# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings 'all';

use File::Basename;
use File::Slurp qw( read_file);
use Cwd 'abs_path';
use lib abs_path(dirname(__FILE__) . '/../lib');
use lib abs_path(dirname(__FILE__) . '/../scripts');
use File::Temp qw( :seekable );

use Test::More 'no_plan';
use Test::Exception;
use Test::MockObject;

my (%values, %orig_values, @nodes);
my $mock = Test::MockObject->new();
$mock->fake_module( 'Vyatta::Config' );
$mock->fake_module( 'Vyatta::Misc' );
$mock->fake_new('Vyatta::Config');
$mock->set_bound('listNodes', \@nodes);
$mock->mock('returnOrigValue',
            sub {
                my ($self, $path) = @_;
                return if $path =~ / inner-vlan/;
                $path =~ s/[^0-9]//g;
                return $orig_values{$path};
            });
$mock->mock('returnValue',
            sub {
                my ($self, $path) = @_;
                return if $path =~ / inner-vlan/;
                $path =~ s/[^0-9]//g;
                return $values{$path};
            });

# instead of uses
eval read_file(abs_path(dirname(__FILE__)) .
               '/../scripts/vyatta-interfaces.pl');

Vyatta::Interface::parse_netdev_file(
    abs_path(dirname(__FILE__) . '/../sysconf/netdevice')
);

@nodes = qw(100 200);
%orig_values = ( 100 => '100', 200 => '200' );
%values = ( 100 => '100', 200 => '200' );
lives_ok { check_vifs('br0') } 'vifs with unchanged vlan';

%values = ( 100 => '300', 200 => '400' );
lives_ok { check_vifs('br0') } 'vifs with changed vlan';

%values = ( 100 => '100', 200 => '100' );
dies_ok { check_vifs('br0') } 'vifs with colliding vlan';
