#!/usr/bin/perl
#
# Copyright (c) 2018, AT&T Intellectual Property. All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::DistributedDataplane;

use strict;
use warnings;
use Readonly;

use Config::Tiny;
use Vyatta::Config;
use Vyatta::Interface;

my $CONTROLLER_CONF = '/etc/vyatta/controller.conf';

sub get_controller_ip {
    my $config = shift;

    $config = Vyatta::Config->new('distributed')
      unless defined($config);

    my $ctrl_ip = $config->returnValue('controller address');
    unless ( defined($ctrl_ip) ) {

        # fallback to config file for special case

        $config = Config::Tiny->read($CONTROLLER_CONF);

        if ( defined($config) && defined( $config->{Controller} ) ) {
            $ctrl_ip = $config->{Controller}->{ip};
        }
    }

    return $ctrl_ip;
}

sub get_vplane_ip {
    my ( $dpid, $config ) = @_;

    $config = Vyatta::Config->new('distributed')
      unless defined($config);

    my $vplane_ip = $config->returnValue("dataplane $dpid address");
    unless ( defined($vplane_ip) ) {

        # fallback to config file
        my $section = "Dataplane.fabric$dpid";

        $config = Config::Tiny->read($CONTROLLER_CONF);

        if ( defined($config) && defined( $config->{$section} ) ) {
            $vplane_ip = $config->{$section}->{ip};
        }
    }

    return $vplane_ip;
}

# Reworking of vyatta-interfaces.pl::check_device() that loops through
# ALL dataplane interfaces performing the slightly-rearranged logic from
# check_device().
sub check_devices {
	my $cfg = shift;

	my $dist_cfg = Vyatta::Config->new('distributed');
	my $localip = get_controller_ip($dist_cfg);

	my %err_map;

	foreach my $dpInt ( $cfg->listNodes("interfaces dataplane") ) {
		my $intf = new Vyatta::Interface($dpInt);
		my $dpid = $intf->dpid();
		next if ( $dpid == 0 );

		if ( $dist_cfg->exists('controller') ) {
			$err_map{$dpInt} = 'dataplane ' . $dpid . ' is not configured'
				unless $dist_cfg->exists("dataplane $dpid");
		} else {
			unless ( defined($localip) ) {
				$err_map{$dpInt} =
					'IP address for controller is not configured';
				next;
			}

			my $remoteip = get_vplane_ip( $dpid, $cfg );
			$err_map{$dpInt} =
				'IP address for dataplane ' . $dpid . ' is not configured'
				unless ( defined($remoteip) );
		}
	}

    foreach my $name ( sort keys %err_map ) {
        printf "interfaces dataplane %s: %s\n", $name, $err_map{$name};
    }

    if (keys %err_map > 0) {
        return 1;
    }
	return 0;
}


1;

