# Module: Platform.pm
# Functions to assist with the Platform capabilities
#
# Copyright (c) 2018-2019 AT&T Intellectual Property.
#    All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::Platform;
use Readonly;
use strict;
use warnings;
use Vyatta::Configd;
use Vyatta::FeatureConfig qw(get_cfg get_cfg_file get_cfg_value);
use Vyatta::SwitchConfig
  qw(get_hwcfg is_hw_interface_cached get_hwcfg_map get_hwcfg_file );
require Exporter;

our @ISA = qw (Exporter);
our @EXPORT_OK =
  qw (check_interface_features check_security_features check_proxy_arp get_platform_feature_limits is_supported_platform_feature);

Readonly my $PLATFORM_CONF      => '/run/dataplane/platform.conf';
Readonly my $PLATFORM_HW        => '/opt/vyatta/etc/hardware-features';
Readonly my $HW_FEATURE_SECTION => 'hardware-features';
Readonly my $HW_INTERFACE_FEATURE_SECTION => 'hardware-interface-features';
Readonly my $HW_INTERFACE_ROUTER_FEATURE_SECTION =>
  'hardware-interface-router-features';
Readonly my $HW_INTERFACE_SWITCH_FEATURE_SECTION =>
  'hardware-interface-switch-features';
Readonly my $SW_INTERFACE_FEATURE_SECTION  => 'software-interface-features';
Readonly my $ALL_INTERFACE_FEATURE_SECTION => 'all-interface-features';

my $client = Vyatta::Configd::Client->new();

sub get_platform_type {
    return unless eval 'use Vyatta::PlatformConfig; 1';

    my ( $platf_type, $def_platf_type );

    $def_platf_type = Vyatta::PlatformConfig::get_cfg( 'platform-type', 1 );
    return unless defined($def_platf_type) && $def_platf_type ne "";

    $platf_type = Vyatta::PlatformConfig::get_cfg('platform-type');
    if ( !defined($platf_type) || $platf_type eq "" ) {
        $platf_type = $def_platf_type;
    }

    return $platf_type;
}

#
# Walk the given tree of config, calling the func for each new node, and going
# no deeper if func returns a non 0 value. The walk will still continue over the
# rest of the nodes in the tree. The path taken to get to the current node  is
# in $words
#
sub walk_tree {
    my ( $words, $node, $func, $args ) = @_;

    return if &$func( $words, $args );

    if ( ref($node) eq 'ARRAY' ) {
        foreach my $k ( 0 .. $#{$node} ) {
            walk_tree( "$words $node->[$k]", $node->[$k], $func, $args );
        }
    } elsif ( ref($node) eq 'HASH' ) {
        foreach my $k ( sort ( keys( %{$node} ) ) ) {
            walk_tree( "$words $k", $node->{$k}, $func, $args );
        }
    } else {
        if ( defined $node ) {
            return if &$func( "$words $node", $args );
        }
    }
}

#
# Check if the config in $words is supported on some HW platforms.
# If it is then check if it is supported on this platform.
# return 1 if config is not supported on this platform.
sub check_intf_config_files {
    my ( $hw_file, $conf_file, $words, $ifname, $intf_type, $section,
        $conf_section )
      = @_;
    my $use_intf_type;

    if ( !defined($conf_section) ) {
        $conf_section = $section;
    }

    # get value per interface type if not set for all interfaces.
    my $val = get_cfg_value( $hw_file, $section, $words );
    if ( !defined($val) ) {
        $val = get_cfg_value( $hw_file, $section, "$words.$intf_type" );
        $use_intf_type = 1;
    }

    return 0 unless defined($val);

    if ( $val == 0 ) {
        return 1;
    }

    my $plat_val;
    if ( !defined $use_intf_type ) {
        eval { $plat_val = get_cfg_value( $conf_file, $conf_section, $words ); };
    } else {
        eval {
            $plat_val =
              get_cfg_value( $conf_file, $conf_section, "$words.$intf_type" );
        };
    }
    if ( defined($plat_val) ) {
        return 0 if ( $plat_val eq "1" );    # Allow on all interfaces
        my @allowed = split( ',', $plat_val );
        foreach my $i (@allowed) {
            return 0 if ( "dp0" . $i eq $ifname );
        }
    }
    return 1;
}

#
# Check if the given config line should be blocked.  If the interface is not
# one of the ones that should be blocked then return early if a hardware
# feature, but check in all cases if it is a software feature.  This allows
# us to block commands that are hardware specific on SW interfaces
#
# $words is the config in the form:
#   "interfaces dataplane dp0xe12 hardware-switching disable"
#
# In the config files it is in the form:
#   "hardware-switching=1"                   -- all interfaces
#   "hardware-switching.<interface_type>=1"  -- all interfaces of that type
#   "hardware-switching.dataplane=p8,p9"     -- interfaces p8 and p9
#   "firewall.local.switch_vif=1"            -- all switch vifs
#
sub check_platform_interface_feature {
    my ( $words, $state ) = @_;
    my $interfaces = $$state[0];    # The list of interfaces to block on
    my $allmsg     = $$state[1];
    my $hw_file    = $$state[2];
    my $conf_file  = $$state[3];

    $words =~ s/^\s+//g;
    my @words_arr = split( /\s+/, $words );

    my $intf_type = $words_arr[1];
    my $ifname    = $words_arr[2];

    return if ( not defined $ifname );

    my $vif       = $words_arr[3];
    my $feat_path = $words;          # for error string
    my $remove    = 3;

    if ( $intf_type eq "dataplane" or $intf_type eq "switch" ) {

        # Is this a vif command and will there be at least one word left?
        if ( defined $vif and $vif eq "vif" and scalar @words_arr > 5 ) {
            $intf_type = $intf_type . "_vif";
            $remove    = 5;
        }
    }

    splice @words_arr, 0, $remove;
    $words = join( ' ', @words_arr );
    $words =~ s/ /./g;

    my $val;
    if ( not defined( %{$interfaces}{$ifname} ) ) {

        # if this is a pure SW interface
        $val =
          check_intf_config_files( $hw_file, $conf_file, $words,
            $ifname, $intf_type, $SW_INTERFACE_FEATURE_SECTION );
        if ( $val == 1 ) {
            push(
                @{$allmsg},
                (
                    "[$feat_path]",
"Not supported on software interface $ifname on this platform\n"
                )
            );
            return 1;
        }
    }

    $val = check_intf_config_files( $hw_file, $conf_file, $words,
        $ifname, $intf_type, $ALL_INTERFACE_FEATURE_SECTION );

    if ( $val == 1 ) {
        push(
            @{$allmsg},
            ( "[$feat_path]", "Not supported on $ifname on this platform\n" )
        );
        return 1;
    }
    if ( not defined %{$interfaces}{$ifname} ) {
        return;
    }
    if ( %{$interfaces}{$ifname} eq "hw-disabled" ) {
        return;
    }

    # Hardware Interface features occur in this section of the hw_file:
    #
    # [hardware-interface-features]
    #   Applies on any hardware interface
    #
    # But additionally can appear in these 2 sections of the platform's
    # conf_file.
    #
    # [hardware-interface-router-features]
    #   Applies on hw interface if the platform type is router
    #
    # [hardware-interface-switch-features]
    #   Applies on hw interface if the platform type is switch
    #
    my @sections = ($HW_INTERFACE_FEATURE_SECTION);

    my $platf_type = get_platform_type();

    if ( defined($platf_type) ) {
        if ( $platf_type eq 'router' ) {
            push @sections, $HW_INTERFACE_ROUTER_FEATURE_SECTION;
        } else {
            push @sections, $HW_INTERFACE_SWITCH_FEATURE_SECTION;
        }
    }

    foreach my $section (@sections) {
        $val =
          check_intf_config_files( $hw_file, $conf_file, $words,
            $ifname, $intf_type, $HW_INTERFACE_FEATURE_SECTION, $section );

        if ( $val == 0 ) {
            return ($val);
        }
    }

    if (
        check_intf_config_files(
            $hw_file,             $conf_file,
            "hardware-switching", $ifname,
            $intf_type,           $HW_INTERFACE_FEATURE_SECTION
        ) == 0
      )
    {
        push(
            @{$allmsg},
            (
                "[$feat_path]",
"Interface dataplane $ifname must have hardware-switching disabled\n"
            )
        );
    } else {
        push(
            @{$allmsg},
            ( "[$feat_path]", "Not supported on $ifname on this platform\n" )
        );
    }
    return ($val);
}

sub find_physical_switch {
    my ( $words, $switch ) = @_;

    if ( $words =~ /switch (sw\d*) physical-switch/ ) {
        $$switch = $1;
        return 1;
    }
    return 0;
}

# If we have a switch vif, and the switch is the one with the physical switch then
# if we have some hardware interfaces they must belong to this switch, therefore the
# vifs on it should be considered for blocking.
sub find_blocked_interfaces {
    my ( $words, $state ) = @_;

    my $switch     = $$state[0];
    my $interfaces = $$state[1];

    if ( $words =~ /switch (sw\d*) vif (\d*)$/ ) {
        if ( $switch eq $1 ) {
            my $count = keys %{$interfaces};
            if ( $count > 0 ) {
                ${$interfaces}{$1} = 1;
            }
        }
    }
    return 0;
}

#
# Check the interface features that are configured and see if any of them
# should be blocked on here.
#
# Blocking should be checked if the interface is one that has HW processing.
# That is, either an interface that is a hardware one (that does not have
# hardware switching disabled) or a switch vif where any of the interfaces
# in the switch have hardware processing.
#
# If the interface should be checked, and the feature is listed in the
# hardware-features file, but not supported in the platform.conf file then
# block it.
#
# For interfaces, it can be blocked based on an interface type, and on
# specific interfaces. An interface type is taken from the cli, with '_vif'
# appended if it is a vif.
sub check_interface_features {
    my $swcfg = shift;
    my $fail;
    my @allmsg;
    my %interfaces = get_hwcfg_map($swcfg);
    my ( $conf_file, $conf_fh ) = get_cfg_file($PLATFORM_CONF);

    foreach my $i ( keys %interfaces ) {
        if ( !is_hw_interface_cached( $i, $swcfg ) ) {

            # As we use this to find the set of interface to check against we
            # need to do this check here in case it is blocked.
            my $allowed =
              get_cfg_value( $conf_file, $HW_INTERFACE_FEATURE_SECTION,
                "hardware-switching" );
            $interfaces{$i} = "hw-disabled" if $allowed;
        }
    }

    # Find out which interface has the physical switch. We need this to work
    # out whether a switch vif belongs to a switch with a hardware interfaces.
    # We can't check this based on config alone due to the implicit mapping
    # of switch to physical-switch.
    my $switch;
    my $phy_switch;
    eval {
        $switch = $client->tree_get_hash( "interfaces switch",
            { "encoding" => "internal" } );
    };
    if ( defined $switch ) {
        my $switch_words = "";
        walk_tree( $switch_words, $switch, \&find_physical_switch,
            \$phy_switch );

        $phy_switch = "sw0" if not defined $phy_switch;
        my @state = ( $phy_switch, \%interfaces );

        # Find the set of interfaces we should consider blocking config on.
        # This adds switch vifs to the existing hardware ones.
        walk_tree( $switch_words, $switch, \&find_blocked_interfaces, \@state );
    }

    my $words = "";
    my $tree =
      $client->tree_get_hash( "interfaces", { "encoding" => "internal" } );
    my ( $hw_file, $hw_fh ) = get_cfg_file($PLATFORM_HW);
    my @state = ( \%interfaces, \@allmsg, $hw_file, $conf_file );
    walk_tree( $words, $tree, \&check_platform_interface_feature, \@state );
    close($hw_fh)   if defined($hw_fh);
    close($conf_fh) if defined($conf_fh);

    if ( scalar @allmsg ) {
        print join( "\n", @allmsg ) . "\n";
        return 1;
    }
}

# For a given feature, check if it is platform-dependent and then if
# so check that the platform advertises support for it
sub is_supported_platform_feature {
    my ( $feat, $hw_file, $conf_file ) = @_;
    my ( $hw_fh, $conf_fh );
    my $supported;

    ( $hw_file, $hw_fh ) = get_cfg_file($PLATFORM_HW)
      if !defined($hw_file);
    ( $conf_file, $conf_fh ) = get_cfg_file($PLATFORM_CONF)
      if !defined($conf_file);

    my $plat_dep_feat = get_cfg_value( $hw_file, $HW_FEATURE_SECTION, $feat );
    if ($plat_dep_feat) {
        $supported = get_cfg_value( $conf_file, $HW_FEATURE_SECTION, $feat );
        $supported = 0 if !defined($supported);
    } else {
        $supported = 1;
    }

    close($hw_fh)   if defined($hw_fh);
    close($conf_fh) if defined($conf_fh);

    return $supported;
}

#
# For the given config as a string of words check if it is one that is in the
# set of features that are supported in some Hardware platform. If it is in there
# then block it if not supported on this platform.
#
sub check_platform_non_intf_features {
    my ( $feat, $state ) = @_;
    my $allmsg    = $$state[0];
    my $hw_file   = $$state[1];
    my $conf_file = $$state[2];

    # Strip off leading spaces then replace spaces with dots. Keep a copy with
    # spaces for use when printing errors.
    $feat =~ s/^\s+//g;
    my $feat_path = $feat;
    $feat =~ s/ /./g;

    my $supported =
      is_supported_platform_feature( $feat, $hw_file, $conf_file );
    if ( !$supported ) {
        push(
            @{$allmsg},
            ( "[$feat_path]", "Not supported on this platform\n" )
        );
        return 1;
    }
    return 0;
}

# Check that all the config under the security tree is acceptable on this platform.
sub check_security_features {
    my $fail;
    my @allmsg;
    my %interfaces = get_hwcfg();

    return 0 if ( !%interfaces );

    my ( $hw_file,   $hw_fh )   = get_cfg_file($PLATFORM_HW);
    my ( $conf_file, $conf_fh ) = get_cfg_file($PLATFORM_CONF);
    my @state = ( \@allmsg, $hw_file, $conf_file );
    my $tree =
      $client->tree_get_hash( "security", { "encoding" => "internal" } );
    walk_tree( "", $tree, \&check_platform_non_intf_features, \@state );
    close($hw_fh);
    close($conf_fh);

    if ( scalar @allmsg ) {
        print join( "\n", @allmsg );
        return 1;
    }
    return 0;
}

# Proxy arp should be blocked on an L2 interface. An interface is L2 if it is part
# of a bridge or a switch. We can't block based on it being a bridge as there
# may already be customers using that config, but we can block based on the interface
# being part of a switch.
# If the platform type is switch, then hardware interfaces may be part of the
# implicit switch
sub check_proxy_arp {
    my $swcfg = shift;
    my @allmsg;
    my $platf_type = get_platform_type();

    my $cfg = Vyatta::Config->new("interfaces");
    foreach my $intf_type ( $cfg->listNodes() ) {
        foreach my $intf ( $cfg->listNodes($intf_type) ) {
            my $arp = ( $cfg->exists("$intf_type $intf ip enable-proxy-arp") );
            if ( defined($arp) ) {
                my $switch = $cfg->exists("$intf_type $intf switch-group");
                if (
                    (
                            defined($platf_type)
                        and $platf_type eq 'switch'
                        and is_hw_interface_cached( $intf, $swcfg )
                    )
                    or defined($switch)
                  )
                {
                    push( @allmsg,
                        "[interfaces $intf_type $intf ip enable-proxy-arp]",
                        "Not supported on L2 interface $intf\n" );
                }
            }
        }
    }
    if ( scalar @allmsg ) {
        print join( "\n", @allmsg ) . "\n";
        return 1;
    }
    return 0;
}

#
# Return platform specific per feature limits if platform.conf exists
# This API takes two parameters: feature to indicate section
# and limits hash with keys(limit) to be queried.
# If the key string is found its value is returned else 0 is returned.
# More feature, key/value can be added for platforms as required.
#
sub get_platform_feature_limits {
    my ( $feature, $limits ) = @_;

    if ( !defined($feature) || ( not -e $PLATFORM_CONF ) ) {
        return;
    }
    my %limits_hash = %$limits;
    while ( my ( $key, $v ) = each %limits_hash ) {

        my $limit_val = get_cfg( $PLATFORM_CONF, $feature, $key );

        if ( !defined($limit_val) ) {
            $limits_hash{$key} = 0;
        } else {
            $limits_hash{$key} = $limit_val;
        }
    }
    return %limits_hash;
}
