#!/usr/bin/perl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

# For interface config validation ONLY.  Runs off 'interfaces' node.
# Aim is to have a top level validation script so we only need to do the
# imports / uses once, and then iterate over the interfaces within the one
# script invocation.  Makes it much faster.

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";

use File::Slurp qw(read_file);
use JSON qw( decode_json );
use Vyatta::Address;
use Vyatta::Config;
import Vyatta::Dataplane;
use Vyatta::DistributedDataplane;
use Vyatta::Interface;

use Vyatta::SwitchConfig qw(check_software_features get_hwcfg_map get_hwcfg_file);
use Vyatta::Platform qw(check_interface_features check_proxy_arp);

# This is a "modulino" (http://www.drdobbs.com/scripts-as-modules/184416165)
exit __PACKAGE__->main()
  unless caller();

# main() should be kept clean of code for specific validations.  Put in a
# line or two that calls your new validation, but DO NOT dump all your code
# into it.
#
# Additionally, NO VALIDATION MAY DIE when called from here.  Otherwise, you
# end up suppressing other errors until your error is fixed, meaning that the
# user has to run validation repeatedly to fix all errors, instead of getting
# a full list on the first pass.
#
sub main {
    my $cfg = Vyatta::Config->new();
    my $status = 0;    # 0 = all ok, non-zero means at least one check failed.

    my ( $swcfg, $sw_fh ) = get_hwcfg_file();

    $status |= check_switch_config($cfg, $swcfg);

    my ( $num_errs, $num_warns ) = Vyatta::Interface::check_dataplane_mtu($cfg);
    $status |= $num_errs;

    $status |= Vyatta::DistributedDataplane::check_devices($cfg);

    $status |= Vyatta::Address::validate_all_addrs();

    $status |= validate_link_speeds_and_duplex($cfg);

    $status |= Vyatta::Platform::check_interface_features($swcfg);

    $status |= Vyatta::Platform::check_proxy_arp($swcfg);

    $status |= validate_breakout($cfg);

    close($sw_fh) if defined($sw_fh);
    return $status;
}

sub create_dataplane_cache {
    require Vyatta::Dataplane;

    # Fetch the current ifconfig for the dataplanes
    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();
    my $response =
      Vyatta::Dataplane::vplane_exec_cmd( "ifconfig -a", $dpids, $dpsocks, 1 );

    for my $dpid ( @{$dpids} ) {
        next unless defined( $response->[$dpid] );

        open( my $fh, '>', "/var/run/ifconfig.$dpid.json" );
        print $fh $response->[$dpid];
        close($fh);
    }
}

# Returns 1 (true) if ok, 0 (false) if not.
sub check_switch_config {
    my ( $cfg, $swcfg ) = @_;

    # Determine if we need to check hardware.
    my $check_hw = 0;
    foreach my $dpInt ( $cfg->listNodes("interfaces dataplane") ) {
        if (
            !$cfg->exists(
                "interfaces dataplane $dpInt hardware-switching disable")
          )
        {
            $check_hw = 1;
        }
    }
    return 0 if ( !$check_hw );

    my %swport_map = get_hwcfg_map($swcfg);
    my %err_map;
    foreach my $dpInt ( $cfg->listNodes("interfaces dataplane") ) {
        next
          if (
            $cfg->exists(
                "interfaces dataplane $dpInt hardware-switching disable")
          );
        if ( defined $swport_map{$dpInt} ) {
            my ( $status, $errmsg ) = check_software_features( $dpInt, $cfg );
            $err_map{$dpInt} = $errmsg if !$status;
        }
    }
    foreach my $name ( sort keys %err_map ) {
        printf "%s\n", $err_map{$name};
    }

    if ( keys %err_map > 0 ) {
        return 1;
    }
    return 0;
}

# Compare the configured dataplane interface speed and duplex
# against the reported current capabilities.
sub validate_link_speeds_and_duplex {
    my $config = shift;
    my %ifconfig;
    my $status = 0;

    my @ifconfig_outs = glob '/var/run/ifconfig.*.json';
    if ( !@ifconfig_outs ) {
        create_dataplane_cache();
        @ifconfig_outs = glob '/var/run/ifconfig.*.json';
    }

    # Read the dataplane caches
    foreach my $ifconfig_out (@ifconfig_outs) {
        my $decoded = decode_json( read_file($ifconfig_out) );
        foreach my $interface ( @{ $decoded->{'interfaces'} } ) {
            my $name = $interface->{'name'};
            $ifconfig{$name} = $interface;
        }
    }

    foreach my $name ( $config->listNodes('interfaces dataplane') ) {
        my $path;

        $path = sprintf "interfaces dataplane %s speed", $name;
        my $speed = $config->returnValue($path);
        $path = sprintf "interfaces dataplane %s duplex", $name;
        my $duplex = $config->returnValue($path);

        my $link_speeds_ref =
          $ifconfig{$name}->{'dev'}->{'capabilities'}->{'full-duplex'}
          if
          exists $ifconfig{$name}->{'dev'}->{'capabilities'}->{'full-duplex'};
        my $link_speeds_hd_ref =
          $ifconfig{$name}->{'dev'}->{'capabilities'}->{'half-duplex'}
          if
          exists $ifconfig{$name}->{'dev'}->{'capabilities'}->{'half-duplex'};

        if ( $duplex eq "full" ) {
            if ( is_speed_in_speed_list( $speed, $link_speeds_ref ) ) {
                next;
            }
        } elsif ( $duplex eq "half" ) {
            if ( is_speed_in_speed_list( $speed, $link_speeds_hd_ref ) ) {
                next;
            }
        } elsif ( $duplex eq "auto" ) {
            if (   is_speed_in_speed_list( $speed, $link_speeds_ref )
                || is_speed_in_speed_list( $speed, $link_speeds_hd_ref ) )
            {
                next;
            }
        } else {
            die "Unknown duplex $duplex!\n";
        }

        printf "Speed %s%s is not supported on port %s\n", $speed,
          $duplex eq "auto" ? "" : " $duplex-duplex", $name;
        $status = 1;
    }

    return $status;
}

# Check to see if named speed is in the list of speeds. The
# named speed is from the YANG enumeration.  The list of
# speeds should be a reference to an array in Mbps.
sub is_speed_in_speed_list {
    my $speed_name     = shift;
    my $speed_list_ref = shift;
    my %port_speeds    = (
        'auto' => 'auto',
        '10m'  => 10,
        '100m' => 100,
        '1g'   => 1000,
        '2.5g' => 2500,
        '10g'  => 10000,
        '25g'  => 25000,
        '40g'  => 40000,
        '100g' => 100000,
    );

    die "Unable to map speed $speed_name for validation!\n"
      if !defined( $port_speeds{$speed_name} );

    my $speed = $port_speeds{$speed_name};

    # If we don't know the speeds for an interface,
    # or the speed is auto, assume a match.
    return 1 if !defined $speed_list_ref or $speed eq "auto";

    foreach my $link_speed ( @{$speed_list_ref} ) {
        return 1 if $link_speed == $speed;
    }
    return 0;
}

sub validate_parent_breakout_cfg {
    my ( $cfg, $intf ) = @_;
    my @cfg_nodes = $cfg->listNodes("$intf");
    my $msg       = "";

    # when an interface is broken out, or reserved for breakout of
    # another interface, the only other commands permitted on it are
    # description and speed
    my @permitted_cmds = ( 'description', 'speed', 'breakout',
                           'breakout-reserved-for' );

    for my $cmd (@cfg_nodes) {
        if ( !grep /$cmd/, @permitted_cmds ) {
            if ( !$cfg->isDefault("$intf $cmd") ) {
                $msg =
                    $msg
                  . "\n [ interfaces dataplane $intf $cmd ]\n\n"
                  . "Command not permitted on interface with breakout config\n";
            }
        }
    }

    return $msg;
}

#
# validate configuration on subports
# ensure that speed and duplex cannot be configured on subports.
# The speed of a subport should always be derived from the parent
#
sub validate_subport_cfg {
    my ( $cfg, $intf ) = @_;
    my $msg = "";

    if ( $cfg->exists("$intf speed") && !$cfg->isDefault("$intf speed") ) {
        $msg = "\n [ interfaces dataplane $intf speed ]\n\n"
          . "Command not permitted on subport. Speed is derived from parent port.\n";
    }
    if ( $cfg->exists("$intf duplex") && !$cfg->isDefault("$intf duplex") ) {
        $msg =
            $msg
          . "\n [ interfaces dataplane $intf duplex ]\n\n"
          . "Command not permitted on subport. Port always operates in full duplex mode.\n";
    }
    return $msg;
}

sub validate_breakout {
    my $config = shift;
    $config->setLevel("interfaces dataplane");
    my @dp_intfs = $config->listNodes();
    my $msg      = '';
    foreach my $intf (@dp_intfs) {
        if ( $config->exists("$intf breakout") ||
             $config->exists("$intf breakout-reserved-for") ) {
            if ( !( $intf =~ /^dp(\d+)ce(\d+)$/ ) ) {
                $msg =
                    $msg
                  . "\n[ interfaces dataplane $intf breakout ]\n\n"
                  . "Breakout only permitted on 100G interfaces (dpXceY)\n";
            }

            $msg = $msg . validate_parent_breakout_cfg( $config, $intf );
        }

        if ( $intf =~ /dp(\d+)ce(\d+)p([0-3])/ ) {
            my $parent = $intf;
            substr( $parent, -2 ) = "";

            if ( !$config->exists("$parent") ) {
                $msg =
                    $msg
                  . "\n[ interfaces dataplane $intf ]\n\n"
                  . "Parent interface $parent not present\n";
            }

            if ( !$config->exists("$parent breakout") ) {
                $msg =
                    $msg
                  . "\n[ interfaces dataplane $intf ]\n\n"
                  . "Breakout command must be specified on $parent\n";
            }

            my $subport = substr( $intf, -1 );
            my $breakout = $config->returnValue("$parent breakout");
            if ( ( defined $breakout ) && ( $subport >= $breakout ) ) {
                $msg =
                    $msg
                  . "\n[ interfaces dataplane $intf ]\n"
                  . "[ interfaces dataplane $parent breakout $breakout ]\n\n"
                  . "Insufficient number of breakout ports specified on parent\n";
            }

            $msg = $msg . validate_subport_cfg( $config, $intf );
        }
    }

    if ($msg) {
        printf($msg);
        return 1;
    }
    return 0;
}
