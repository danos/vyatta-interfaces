# Module: SwitchConfig.pm
# Functions to assist with maintenance of switch configuration.
# Derived class of FeatureConfig
#
# Copyright (c) 2018-2020 AT&T Intellectual Property.
#    All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::SwitchConfig;
use strict;
use warnings;
use File::Slurp;
use Vyatta::FeatureConfig qw(setup_cfg_file set_cfg get_cfg get_cfg_file
  get_default_cfg del_cfg get_cfg_value);
use Vyatta::PortMonitor qw(get_portmonitor_destination_intflist);
use File::Temp ();

require Exporter;

my $MOD_NAME      = "SwitchConfig.pm";
my $SWITCH_CONF   = "/run/vyatta/switch.conf";
my $MAIN_SEC_NAME = "Switch";
my $HW_SEC_NAME   = "Hardware";

our @ISA       = qw (Exporter FeatureConfig);
our @EXPORT_OK = qw (set_switch_cfg get_switch_cfg del_switch_cfg
  create_hwcfg get_hwcfg get_physical_switches get_default_switchports
  get_current_softswitch_name update_port_attr check_software_features is_hw_interface
  verify_int_is_hw get_hwcfg_map get_hwcfg_file is_hw_interface_cached
  interface_exists);

sub setup_switch_cfg_file {
    my ($file) = @_;

    setup_cfg_file( $MOD_NAME, $file, $MAIN_SEC_NAME );
}

sub set_switch_cfg_file {
    my ( $file, $var, $value, $default, $section ) = @_;

    if ( !defined($section) ) {
        $section = $MAIN_SEC_NAME;
    }
    set_cfg( $file, $section, $var, $value, $default );
}

sub set_switch_cfg {
    my ( $var, $value, $default, $section ) = @_;

    if ( !-f $SWITCH_CONF ) {
        setup_switch_cfg_file($SWITCH_CONF);
    }

    set_switch_cfg_file( $SWITCH_CONF, $var, $value, $default, $section );
}

# Use get_switch_cfg_file() / get_switch_cfg_value() if calling multiple times
# as it is much much more efficient (avoids lots of file open/close and file
# parsing)
sub get_switch_cfg {
    my ( $attr, $default, $section ) = @_;

    if ( defined($default) && $default ) {
        return get_default_cfg( $SWITCH_CONF, $attr );
    } else {
        if ( !defined($section) ) {
            $section = $MAIN_SEC_NAME;
        }
        return get_cfg( $SWITCH_CONF, $section, $attr );
    }
}

# Similar to get_switch_cfg, but uses already opened file ($cfg) to speed up
# the operation.
sub get_switch_cfg_value {
    my ( $cfg, $attr, $default, $section ) = @_;

    if ( defined($default) && $default ) {
        return get_default_cfg_value( $cfg, $attr );
    } else {
        if ( !defined($section) ) {
            $section = $MAIN_SEC_NAME;
        }
        return get_cfg_value( $cfg, $section, $attr );
    }
}

sub del_switch_cfg {
    my ( $attr, $section ) = @_;
    if ( !defined($section) ) {
        $section = $MAIN_SEC_NAME;
    }
    return del_cfg( $SWITCH_CONF, $section, $attr );
}

sub build_switchport_map {
    my @results = @_;
    my %swport_map;

    foreach my $result (@results) {
        my @intfs = @{ $result->{interfaces} };
        foreach my $intf (@intfs) {
            my $switch = $intf->{dev}->{hw_switch_id};
            next unless ( $intf->{type} eq "ether"
                && defined($switch) );

            if ( !defined( $swport_map{$switch} ) ) {
                @{ $swport_map{$switch} } = ();
            }
            push( @{ $swport_map{$switch} }, $intf->{name} );
        }
    }
    return %swport_map;
}

sub get_ifconfig {
    return unless eval 'use Vyatta::Dataplane qw(vplane_exec_cmd); 1';
    return unless eval 'use JSON qw(decode_json); 1';

    my @results;
    my ( $dpids, $dpsocks ) = Vyatta::Dataplane::setup_fabric_conns();
    my $response = vplane_exec_cmd( "ifconfig -a", $dpids, $dpsocks, 1 );

    # Decode the response from each vplane
    for my $dpid ( @{$dpids} ) {
        next unless defined( $response->[$dpid] );
        my $decoded = decode_json( $response->[$dpid] );
        $results[$dpid] = $decoded;
    }
    return @results;
}

sub get_mgmt_ports {
    my @results   = @_;
    my @mgmtports = ();

    foreach my $result (@results) {
        my @intfs = @{ $result->{interfaces} };
        foreach my $intf (@intfs) {
            my $is_mgmt_port = $intf->{dev}->{management};
            next unless ( defined($is_mgmt_port) && $is_mgmt_port );

            push( @mgmtports, $intf->{name} );
        }
    }
    return @mgmtports;
}

sub create_hwcfg {
    my @ifconfig   = get_ifconfig();
    my %swport_map = build_switchport_map(@ifconfig);
    my $count      = 0;

    # Set the switch state in a file out of the way to avoid readers
    # seeing partial state (including an empty file which would result
    # in an error)
    my $tmp = File::Temp->new(
        TEMPLATE => $SWITCH_CONF . "XXXXXX",
        UNLINK   => 0
    );
    my $tmp_file = $tmp->filename;
    setup_switch_cfg_file($tmp_file);
    set_switch_cfg_file( $tmp_file, "ManagementPorts",
        join( ',', sort( get_mgmt_ports(@ifconfig) ) ),
        0, $HW_SEC_NAME );
    my @switches = ( keys %swport_map );
    set_switch_cfg_file( $tmp_file, "HwSwitchCount", scalar @switches,
        0, $HW_SEC_NAME );
    foreach my $hw_switch (@switches) {
        set_switch_cfg_file( $tmp_file, "HwSwitch$count.id",
            $hw_switch, 0, $HW_SEC_NAME );
        my $intfs = join( ',', sort @{ $swport_map{$hw_switch} } );
        set_switch_cfg_file( $tmp_file, "HwSwitch$count.intfs",
            $intfs, 0, $HW_SEC_NAME );
    }

    # Atomically move the file into place, ensuring it has the
    # appropriate permissions
    chmod( 0666 & ~umask(), $tmp_file );
    rename( $tmp_file, $SWITCH_CONF );
}

sub gen_subport_names {
    my $swport_map = shift;

    for my $intf ( keys %{$swport_map} ) {

        # 100G interfaces can have up to 4 subports
        if ( $intf =~ /^dp(\d+)ce(\d+)$/ ) {
            for ( my $i = 0 ; $i < 4 ; $i++ ) {
                my $subport_name = "${intf}p${i}";
                $swport_map->{$subport_name} = $swport_map->{$intf};
            }
        }
    }
}

sub get_other_hw_interfaces {
    my $swport_map = shift;
    my @bonding_intfs;
    return unless eval 'use Vyatta::Config; 1';

    my $client = Vyatta::Config->new();

    @bonding_intfs = $client->listNodes("interfaces bonding");

    return if !@bonding_intfs;

    return
      unless eval 'use Vyatta::Platform qw( is_supported_platform_feature ); 1';

    return
      if !is_supported_platform_feature( "bonding.hardware-members-only",
        undef, undef );

    foreach my $bonding_intf (@bonding_intfs) {

        # Hard code bonding interfaces to switch 0, since in the case
        # of the presence of multiple physical switches it isn't clear
        # what behaviour we'd want in general.
        $swport_map->{$bonding_intf} = 0;
    }
}

# For efficiency, use get_hwcfg_map() on an already opened SWITCH_CONF file
# if calling multiple times as this avoids unnecessary file operations.
sub get_hwcfg {
    my %swport_map = ();

    if ( !-f $SWITCH_CONF ) {
        create_hwcfg();
    }
    my ( $swcfg, $fh ) = get_cfg_file($SWITCH_CONF);

    my $hw_switch_cnt =
      get_switch_cfg_value( $swcfg, "HwSwitchCount", 0, $HW_SEC_NAME );

    for ( my $id = 0 ; $id < $hw_switch_cnt ; $id++ ) {
        my $intfs =
          get_switch_cfg_value( $swcfg, "HwSwitch$id.intfs", 0, $HW_SEC_NAME );
        my @intf_arr = split( ',', $intfs );
        foreach my $intf (@intf_arr) {
            $swport_map{$intf} = $id;
        }
    }
    close($fh) if defined($fh);
    gen_subport_names( \%swport_map );
    get_other_hw_interfaces( \%swport_map );
    return %swport_map;
}

sub get_hwcfg_file {
    if ( !-f $SWITCH_CONF ) {
        create_hwcfg();
    }
    return ( get_cfg_file($SWITCH_CONF) );
}

# Similar to get_hwcfg() but uses an already opened and parsed file ($swcfg)
# to avoid repeated file operations when requesting the same data multiple
# times.
sub get_hwcfg_map {
    my $swcfg = shift;

    my %swport_map = ();

    my $hw_switch_cnt =
      get_switch_cfg_value( $swcfg, "HwSwitchCount", 0, $HW_SEC_NAME );

    for ( my $id = 0 ; $id < $hw_switch_cnt ; $id++ ) {
        my $intfs =
          get_switch_cfg_value( $swcfg, "HwSwitch$id.intfs", 0, $HW_SEC_NAME );
        my @intf_arr = split( ',', $intfs );
        foreach my $intf (@intf_arr) {
            $swport_map{$intf} = $id;
        }
    }
    gen_subport_names( \%swport_map );
    get_other_hw_interfaces( \%swport_map );
    return %swport_map;
}

sub get_physical_switches {
    my @switches;
    my $switch_cnt = get_switch_cfg( "HwSwitchCount", 0, $HW_SEC_NAME );
    for ( my $id = 0 ; $id < $switch_cnt ; $id++ ) {
        my $switch_id = get_switch_cfg( "HwSwitch$id.id", 0, $HW_SEC_NAME );
        push( @switches, $switch_id );
    }
    return @switches;
}

#
# determine the switchports in 'default' state
# i.e., without any user configuration to put them in L2 or L3 mode
#
sub get_default_switchports {
    return unless eval 'use Vyatta::Configd; 1';

    my $client          = Vyatta::Configd::Client->new();
    my %swports         = get_hwcfg();
    my @default_swports = ();
    my @portmon_dest = get_portmonitor_destination_intflist();

    foreach my $swport ( keys %swports ) {
        my $cfg_str = "interfaces dataplane $swport";
        my $ifcfg   = $client->get($cfg_str);
        next
          if ( grep /(bridge-group|switch-group|address|bond-group)/,
            @{$ifcfg} );
        next
          if ( grep /$swport/, @portmon_dest );
        next
          if (
            $client->node_exists(
                $Vyatta::Configd::Client::AUTO,
                "$cfg_str hardware-switching disable"
            )
          );
        push( @default_swports, $swport );
    }
    return sort @default_swports;
}

sub get_current_softswitch_name {
    my ($ifname) = @_;

    return
      if $ifname =~  m/vrrp/;
    my ($master) = grep { /^upper_/ } read_dir("/sys/class/net/$ifname");
    return
      if !defined($master);

    $master =~ s/^upper_//;
    return $master;
}

sub update_port_attr {
    return unless eval 'use Vyatta::VPlaned; 1';

    my ( $ifname, $attr, $val, $action ) = @_;

    my $cstore = new Vyatta::VPlaned;
    $cstore->store(
        "switchport $ifname",
        "switchport $ifname $attr $val",
        $ifname, $action
    );
}

sub check_software_features {
    my ( $ifname, $cfg ) = @_;
    my $cfg_prefix   = "interfaces dataplane $ifname";
    my $sw_feat_found = 0;
    if ( $cfg->exists("$cfg_prefix switch-group") ) {
        my $cfg_switch = $cfg->returnValue("$cfg_prefix switch-group switch");
        if ( defined($cfg_switch)
            && (
                !$cfg->exists("interfaces switch $cfg_switch physical-switch") )
          )
        {
            $sw_feat_found = 1;
        }
    }
    return ( 0,
        "Interface dataplane $ifname must have hardware-switching disabled\n" )
      if ($sw_feat_found);
    return ( 1, "" );
}

sub is_hw_interface {
    return unless eval 'use Vyatta::Configd; 1';

    my $intf       = shift;
    my $client     = Vyatta::Configd::Client->new();
    my %swport_map = get_hwcfg();

    if ( defined( $swport_map{$intf} ) ) {
        if (
            !$client->node_exists(
                $Vyatta::Configd::Client::AUTO,
                "interfaces dataplane $intf hardware-switching disable"
            )
          )
        {
            return 1;
        }
    }
    return 0;
}

sub is_hw_interface_cached {
    return unless eval 'use Vyatta::Configd; 1';

    my $intf       = shift;
    my $swcfg      = shift;
    my $client     = Vyatta::Configd::Client->new();
    my %swport_map = get_hwcfg_map($swcfg);

    if ( defined( $swport_map{$intf} ) ) {
        if (
            !$client->node_exists(
                $Vyatta::Configd::Client::AUTO,
                "interfaces dataplane $intf hardware-switching disable"
            )
          )
        {
            return 1;
        }
    }
    return 0;
}

sub verify_int_is_hw {
    my ( $intf_name, $cfgifs ) = @_;
    my ( $msg, $failure, $warning );

    my $matches = grep { $_ eq $intf_name } @$cfgifs;
    if ( $matches > 0 ) {
        if ( is_hw_interface($intf_name) ) {
            $msg     = "Not allowed on hardware-switched interface\n";
            $failure = 1;
        }
    } else {
        $msg = "Warning: interface $intf_name does not exist on this system\n";
        $warning = 1;
    }
    return ( $msg, $failure, $warning );
}

sub interface_exists {
    my $intf = shift;

    return 1 if ( -e "/sys/class/net/$intf" );

    return 0;
}
