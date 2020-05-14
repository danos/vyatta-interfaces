#!/usr/bin/perl

# Copyright (c) 2018, AT&T Intellectual Property.  All rights reserved.

# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings 'all';

use File::Basename;
use Cwd 'abs_path';
use lib abs_path(dirname(__FILE__) . '/../lib');
use File::Temp qw( :seekable );

use Test::More 'no_plan';

use Test::MockObject;

use Test::Exception;

use Test::Warn;

use Test::Output;

my $debug = 0;

my $mock = Test::MockObject->new();
$mock->fake_module( 'Vyatta::Config' );
$mock->fake_new('Vyatta::Config');
$mock->fake_module( 'Vyatta::Configd' );
$mock->fake_new('Vyatta::Config::Client',
  call_rpc_hash => sub {return {"receive" => "dp0p1s1", "group" => "1"}}
);
$mock->fake_module( 'Vyatta::Misc',
  get_sysfs_value => sub { return "1" }
);
$mock->fake_module( 'Vyatta::Dataplane' );
$mock->fake_module( 'JSON' );

use_ok('Vyatta::Interface');
use_ok('Vyatta::Address');
use_ok('Vyatta::DistributedDataplane');

Vyatta::Interface::parse_netdev_file(
    abs_path(dirname(__FILE__) . '/../sysconf/netdevice')
);

# The dataplane netdevice type definition comes from vyatta-cfg-dataplane but
# the bonding code still depends on the existence of the dataplane netdevice.
my $netdevice_fh = File::Temp->new();
print $netdevice_fh "dp\tdataplane\n";
$netdevice_fh->seek( 0, SEEK_END );
Vyatta::Interface::parse_netdev_file($netdevice_fh->filename);

ok(Vyatta::Interface->new('lo'), 'new(lo)');
is(Vyatta::Interface->new('oink'), undef, 'new(oink): returns undef');

my $intf = Vyatta::Interface->new('lo');
is($intf->path(), 'interfaces loopback lo', 'lo: path()');
is($intf->physicalDevice(), 'lo', 'lo: physicalDevice()');

SKIP: {
    skip 'Missing mocking of Vyatta::Config and Vyatta::Misc', 8;

    is_deeply(@{[ $intf->address() ]}, qw(), 'lo: address()');
    ok($intf->exists(), 'lo: exists()');
    ok($intf->configured(), 'lo: configured()');
    ok($intf->disabled(), 'lo: disabled()');
    ok($intf->using_dhcp(), 'lo: using_dhcp()');
    ok($intf->flags(), 'lo: flags()');
    ok($intf->up(), 'lo: up()');
    ok($intf->running(), 'lo: running()');
}

$intf = Vyatta::Interface->new('dp0s7');
is($intf->path(), 'interfaces dataplane dp0s7', 'dataplane: path()');

$intf = Vyatta::Interface->new('dp0bond0');
is($intf->path(), 'interfaces bonding dp0bond0', 'bonding: path()');

$intf = Vyatta::Interface->new('dp0bond0.100');
is($intf->path(), 'interfaces bonding dp0bond0 vif 100', 'vif: path()');

# Rather than set up subtly different mocks for the following tests, create
# generic mocks that we can customise per-test.  This makes each test much
# shorter, and avoids duplicate code.

# Vyatta::Config::returnValues()
my %retVals;
sub mock_return_values {
	my ( $path ) = @_;
	if ( !defined $retVals{$path} ) {
		printf("returnValues(): NO entry for $path\n") unless ($debug == 0);
		return undef;
	}
	return $retVals{$path};
}
$mock->mock('returnValues',
			sub { shift; return mock_return_values(shift); });

# Vyatta::Config::returnValue()
my %retVal;
sub mock_return_value {
	my ( $path ) = @_;
	if ( !defined $retVal{$path} ) {
		printf("returnValue(): NO entry for $path\n") unless ($debug == 0);
		return undef;
	}
	return $retVal{$path};
}
$mock->mock('returnValue',
			sub { shift; return mock_return_value(shift); });

# Vyatta::Config::isDefault()
my %isDflt;
sub mock_is_default {
	my ( $path ) = @_;
	if ( !defined $isDflt{$path} ) {
		printf("isDefault(): NO entry for $path\n") unless ($debug == 0);
		return undef;
	}
	return $isDflt{$path};
}
$mock->mock('isDefault',
			sub { shift; return mock_is_default(shift); });

# Vyatta::Config::listNodes()
my %listNodes;
sub mock_list_nodes {
	my ( $path ) = @_;
	if ( !defined $listNodes{$path} ) {
		printf("listNodes(): NO entry for $path\n") unless ($debug == 0);
		return ();
	}
	return (@{$listNodes{$path}});
}
$mock->mock('listNodes',
			sub { shift; return mock_list_nodes(shift); });

# Vyatta::Config::exists()
my %exists;
sub mock_exists {
	my ( $path ) = @_;
	if ( !defined $exists{$path} ) {
		printf("exists(): NO entry for $path\n") unless ($debug == 0);
		return; # Needs to be undefined
	}
	return 1;
}
$mock->mock('exists',
			sub { shift; return mock_exists(shift); });

sub clear_expected_values {
	%retVals = ();
	%retVal = ();
	%isDflt = ();
	%listNodes = ();
	%exists = ();
}

# Set expected values for config queries about the fabric controller interface
# that are constant across all tests.
sub setup_controller {
	$retVals{'distributed controller fabric address'} = '192.168.1.1';

	$listNodes{'interfaces system'} = ['sysIntf0'];
	$retVals{'interfaces system sysIntf0 address'} = '192.168.1.1';
	$retVal{'interfaces system sysIntf0 mtu'} = '1500';
}

# Make sure validate_dev_mtu dies / warns / lives as expected.  'local'
# indicates dataplane interface that is local to controller, whereas 'remote'
# (indicated by dpX where X > 0) indicates an interface on a remote dataplane.

subtest 'validate_dev_mtu_local_intf_pass' => sub {
	lives_ok { Vyatta::Interface::validate_dev_mtu( 'dp0s1', 1500, 'SET' ),
		'MTU validation passed'};
};

subtest 'validate_dev_mtu_remote_intf_pass' => sub {
	clear_expected_values();

	setup_controller();

	# MTU 100 bytes less than sysIntf0.
	lives_ok { Vyatta::Interface::validate_dev_mtu( 'dp1s1', 1400, 'SET' ),
		'MTU validation passed'};
};

subtest 'validate_dev_mtu_warns' => sub {
	clear_expected_values();

	setup_controller();

	$isDflt{'interfaces dataplane dp1s1 mtu'} = 1;

	warnings_exist {
		Vyatta::Interface::validate_dev_mtu( 'dp1s1', 1500, 'SET' ) }
	[qr/^MTU of fabric interface sysIntf0 = 1500/], "Warning generated";
};

subtest 'validate_dev_mtu_dies' => sub {
	clear_expected_values();

	setup_controller();

	throws_ok { Vyatta::Interface::validate_dev_mtu( 'dp1s1', 9999, 'SET' ) }
	qr/Fabric interface sysIntf0 must have mtu/, 'Should die';
};

# More thorough tests on underlying validate_dev_mtu_silent() follow ...
subtest 'validate_dev_mtu_silent_local_intf_pass' => sub {
	my ( $warn, $err ) =
		Vyatta::Interface::validate_dev_mtu_silent( 'dp0s1', 1500, 'SET' );

	ok($warn eq '');
	ok($err eq '');
};

subtest 'validate_dev_mtu_silent_remote_intf_pass' => sub {
	clear_expected_values();

	setup_controller();

	# 100 bytes (or more) < sysIntf0 MTU.
	my ( $warn, $err ) =
		Vyatta::Interface::validate_dev_mtu_silent( 'dp2s1', 1400, 'SET' );

	ok($warn eq '');
	ok($err eq '');
};

subtest 'validate_dev_mtu_silent_warns' => sub {
	clear_expected_values();

	setup_controller();

	# Trigger code path that will generate our warning.
	$isDflt{'interfaces dataplane dp1s1 mtu'} = 0;

	my ( $warn, $err ) =
		Vyatta::Interface::validate_dev_mtu_silent( 'dp1s1', 1500, 'SET' );

	ok(index($warn, 'MTU of fabric interface sysIntf0 = 1500') != -1);
	ok(index($warn, 'MTU of dp1s1 should be reduced to 1400 or lower') != -1);
	ok($err eq '');
};

subtest 'validate_dev_mtu_silent_dies' => sub {
	clear_expected_values();

	setup_controller();

	my ( $warn, $err ) =
		Vyatta::Interface::validate_dev_mtu_silent( 'dp1s1', 3000, 'SET' );

	ok($warn eq '');
	ok(index($err,  'Fabric interface sysIntf0 must have mtu >= 3100') != -1);
};

# Now test check_dataplane_mtu() deals with multiple warnings and/or errors.
# We don't need to worry about testing local vs remote (distributed) interfaces
# as the lower level tests above have dealt with that.

subtest 'check_dev_mtu_no_dataplane_interfaces' => sub {
	clear_expected_values();

	setup_controller();

	my ( $num_errs, $num_warns ) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 0 );
	ok( $num_warns == 0 );
};

subtest 'check_dev_mtu_no_errors_or_warnings' => sub {
	clear_expected_values();

	setup_controller();

	$listNodes{'interfaces dataplane'} = ['dp1p1'];
	$retVal{'interfaces dataplane dp1p1 mtu'} = 1400;

	my ( $num_errs, $num_warns ) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 0 );
	ok( $num_warns == 0 );
};

subtest 'check_dev_mtu_single_error' => sub {
	clear_expected_values();

	setup_controller();

	$listNodes{'interfaces dataplane'} = ['dp2p3'];
	$retVal{'interfaces dataplane dp2p3 mtu'} = 1600;

	my ( $num_errs, $num_warns) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 1 );
	ok( $num_warns == 0 );

	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp2p3: Fabric interface sysIntf0 must have mtu >= 1700/,
		'MTU error';
};

subtest 'check_dev_mtu_single_error_multiple_interfaces' => sub {
	clear_expected_values();

	setup_controller();

	$listNodes{'interfaces dataplane'} = ['dp2p1', 'dp2p2', 'dp3p1'];
	$retVal{'interfaces dataplane dp2p1 mtu'} = 1300;
	$retVal{'interfaces dataplane dp2p2 mtu'} = 1600; # Generates error
	$retVal{'interfaces dataplane dp3p1 mtu'} = 1400;

	my ( $num_errs, $num_warns ) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 1 );
	ok( $num_warns == 0 );

	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp2p2: Fabric interface sysIntf0 must have mtu >= 1700/,
		'MTU error';
};

subtest 'check_dev_mtu_single_warning' => sub {
	clear_expected_values();

	setup_controller();

	$listNodes{'interfaces dataplane'} = ['dp2p3'];
	$retVal{'interfaces dataplane dp2p3 mtu'} = 1500;
	$isDflt{'interfaces dataplane dp2p3 mtu'} = 0;

	my ( $num_errs, $num_warns ) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 0 );
	ok( $num_warns == 1 );

	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp2p3: MTU of fabric interface sysIntf0 = 1500/,
		'MTU warning';
	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/MTU of dp2p3 should be reduced to 1400 or lower/,
		'MTU warning';
};

subtest 'check_dev_mtu_multiple_errors_and_warnings' => sub {
	clear_expected_values();

	setup_controller();

	$listNodes{'interfaces dataplane'} =
		['dp1p1', 'dp2p2', 'dp2p3', 'dp3p1', 'dp3p3'];

	# Set up 'error' interfaces
	$retVal{'interfaces dataplane dp1p1 mtu'} = 1600; # Generates error
	$retVal{'interfaces dataplane dp2p2 mtu'} = 1400; # OK
	$retVal{'interfaces dataplane dp3p1 mtu'} = 1600; # Generates error

	# Set up 'warning' interfaces
	$retVal{'interfaces dataplane dp2p3 mtu'} = 1500;
	$isDflt{'interfaces dataplane dp2p3 mtu'} = 0;
	$retVal{'interfaces dataplane dp3p3 mtu'} = 1500;
	$isDflt{'interfaces dataplane dp3p3 mtu'} = 0;

	my ( $num_errs, $num_warns ) =
		Vyatta::Interface::check_dataplane_mtu($mock);
	ok( $num_errs == 2 );
	ok( $num_warns == 2 );

	# Check errors
	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp1p1: Fabric interface sysIntf0 must have mtu >= 1700/,
		'MTU error';
	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp3p1: Fabric interface sysIntf0 must have mtu >= 1700/,
		'MTU error';

	# Check warnings
	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp2p3: MTU of fabric interface sysIntf0 = 1500/,
		'MTU warning';

	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/MTU of dp2p3 should be reduced to 1400 or lower/,
		'MTU warning';

	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/interfaces dataplane dp3p3: MTU of fabric interface sysIntf0 = 1500/,
		'MTU warning';
	stdout_like {Vyatta::Interface::check_dataplane_mtu($mock)}
	qr/MTU of dp3p3 should be reduced to 1400 or lower/,
		'MTU warning';
};

# This set of tests verifies the logic behind vyatta-interfaces.pl:check_device
# which is now replaced by Vyatta::DistributedDataplane::check_devices that
# loops through all the dataplane interfaces.
#
sub setup_distributed_controller_address {
	$retVal{'controller address'} = '192.168.1.1';
}

subtest 'check_devices_no_dataplane_interfaces' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 0 );
};

subtest 'check_devices_local_dataplane_interface_ok' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp0p1'];

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 0 );
};

subtest 'check_devices_remote_dataplane_interface_ok_controller' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp1p1'];
	$exists{'controller'} = 1;
	$exists{'dataplane 1'} = 1;

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 0 );
};

subtest 'check_devices_remote_dataplane_interface_fails_dp_not_cfgd' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp1p1'];
	$exists{'controller'} = 1;

	my $status = Vyatta::DistributedDataplane::check_devices($mock);

	ok( $status == 1 );

	stdout_like {Vyatta::DistributedDataplane::check_devices($mock)}
	qr/interfaces dataplane dp1p1: dataplane 1 is not configured/,
		'Dataplane not configured';
};

subtest 'check_devices_remote_dataplane_interface_ok_local_remote_ip' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp2p3'];
	$retVal{'dataplane 2 address'} = '1.1.1.1';

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 0 );
};

subtest 'check_devices_remote_dataplane_interface_fails_localip' => sub {
	clear_expected_values();

	$listNodes{'interfaces dataplane'} = ['dp2p3'];

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 1 );

	stdout_like {Vyatta::DistributedDataplane::check_devices($mock)}
	qr/interfaces dataplane dp2p3: IP address for controller is not configured/,
		'Controller IP not configured';
};

subtest 'check_devices_remote_dataplane_interface_fails_remoteip' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp2p3'];

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 1 );
	stdout_like {Vyatta::DistributedDataplane::check_devices($mock)}
	qr/interfaces dataplane dp2p3: IP address for dataplane 2 is not configured/,
		'Dataplane not configured';
};

subtest 'check_devices_remote_dataplane_interfaces_multiple_errors' => sub {
	clear_expected_values();
	setup_distributed_controller_address();

	$listNodes{'interfaces dataplane'} = ['dp2p3', 'dp3p1'];

	my $status = Vyatta::DistributedDataplane::check_devices($mock);
	ok( $status == 1 );

	stdout_like {Vyatta::DistributedDataplane::check_devices($mock)}
	qr/interfaces dataplane dp2p3: IP address for dataplane 2 is not configured/,
		'Controller IP not configured';
	stdout_like {Vyatta::DistributedDataplane::check_devices($mock)}
	qr/interfaces dataplane dp3p1: IP address for dataplane 3 is not configured/,
		'Controller IP not configured';
};

# check_switch_config
# validate_all_addrs
# validate_link_speeds_and_duplex
