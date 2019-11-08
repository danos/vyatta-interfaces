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

my ($cur_level, %nodes, %address);
sub mkpath {
	my $p = shift;
	return "$cur_level" unless defined($p);
	return (length($cur_level) > 0) ? "$cur_level $p" : $p;
}
my $mock = Test::MockObject->new();
$mock->fake_module( 'Vyatta::Config' );
$mock->fake_module( 'Vyatta::Misc' );
$mock->fake_new('Vyatta::Config');
$mock->mock('listNodes',
	sub {
		my ($self, $p) = @_;
		my $path = mkpath($p);
		print "listNodes: $path\n";
		my $list = $nodes{$path};
		return @$list if defined($list);
		return;
	});
$mock->mock('returnValues',
            sub {
                my ($self, $p) = @_;
		my $path = mkpath($p);
		print "returnValues: $path\n";
		if ($path =~ m/dataplane (\S+) address/) {
			my $a = $address{$1};
			return @$a;
		}
		return;
            });
$mock->mock('exists',
            sub {
		my ($self, $p) = @_;
		my $path = mkpath($p);
		print "exists: $path\n";
		return exists($nodes{$path});
	    });
$mock->mock('setLevel',
	sub {
		my ($self, $path) = @_;
		print "setLevelCalled: cur=$cur_level, new=$path\n";
		$cur_level = defined($path) ? "$path" : '';
	});
		

# instead of uses
use_ok('Vyatta::Address');

Vyatta::Interface::parse_netdev_file(
    abs_path(dirname(__FILE__) . '/../sysconf/netdevice')
);

$cur_level='';
$nodes{interfaces} = [ qw(dataplane) ];
$nodes{'interfaces dataplane'} = [ qw(dp0s3 dp0s4) ];

$address{dp0s3} = [ qw(3.1.1.1/24 3.1.2.1/24) ];
$address{dp0s4} = [ qw(4.1.1.1/24 4.1.2.1/24) ];
lives_ok { Vyatta::Address::validate_all_addrs(), 'valid address set' };

$cur_level='';
$address{dp0s4} = [ qw(4.1.1.1/24 3.1.2.1/24) ];
dies_ok { Vyatta::Address::validate_all_addrs(), 'duplicate address' };

$cur_level='';
$address{dp0s4} = [ qw(4.1.1.1/24 4.1.1.2/24) ];
lives_ok { Vyatta::Address::validate_all_addrs(), 'same subnets in an interface' };

$cur_level='';
$address{dp0s4} = [ qw(4.1.1.1/24 3.1.1.2/24) ];
dies_ok { Vyatta::Address::validate_all_addrs(), 'same subnets on different interface' };

$cur_level='';
$address{dp0s4} = [ qw(4.1.1.1/24 3.1.1.2/23) ];
dies_ok { Vyatta::Address::validate_all_addrs(), 'overlapped subnets' };

$cur_level='';
$nodes{'interfaces dataplane'} = [ qw(dp0s3 dp0s4 dp0s5 dp0s6) ];
$nodes{'routing routing-instance' } = [ qw(red green) ];
$nodes{'routing routing-instance red interface' } = [ qw(dp0s4) ];
$nodes{'routing routing-instance green interface' } = [ qw(dp0s5 dp0s6) ];
$address{dp0s3} = [ qw(3.1.1.1/24 3.1.2.1/24) ];
$address{dp0s4} = [ qw(4.1.1.1/24 4.1.2.1/24) ];
$address{dp0s5} = [ qw(5.1.1.1/24 5.1.2.1/24) ];
$address{dp0s6} = [ qw(6.1.1.1/24 6.1.2.1/24) ];
lives_ok { Vyatta::Address::validate_all_addrs(), 'no overlaps with routing instance' };


$cur_level='';
$address{dp0s3} = [ qw(3.1.1.1/24 3.1.2.1/24) ];
$address{dp0s4} = [ qw(3.1.1.1/24 3.1.2.1/24) ];
$address{dp0s5} = [ qw(3.1.1.1/24 3.1.2.1/24) ];
lives_ok { Vyatta::Address::validate_all_addrs(), 'duplicate in different vrf' };

$cur_level='';
$address{dp0s5} = [ qw(4.1.1.1/24 4.1.2.1/24) ];
$address{dp0s6} = [ qw(4.1.1.1/24 4.1.2.1/24) ];
dies_ok { Vyatta::Address::validate_all_addrs(), 'duplicate in same vrf' };
