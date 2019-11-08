# Module: VIFConfig.pm
# Functions to assist with vif configuration
# Derived from vyatta-interfaces.pl
#
# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2007-2017, Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::VIFConfig;

use strict;
use warnings;

use File::Slurp qw(read_dir);

use Vyatta::Config;
use Vyatta::Misc qw(get_sysfs_value);
use Vyatta::Interface ();

my $dbg;

sub warn_failure {
    my $cmd = shift;
    print "CMD $cmd\n" if ($dbg);
    system($cmd) == 0 or warn "'$cmd' failed\n";
}

sub update_pvid {
    my ( $vif, $dev, $parent, $config ) = @_;
    return unless $dev;

    $parent = new Vyatta::Interface($dev) unless $parent;
    warn("Unable to connect to Vyatta Config in setting vlan-protocol"), return unless $parent;

    $config = new Vyatta::Config( $parent->path() ) unless $config;
    my $pvid = $config->returnValue("vlan-protocol");

    my $vlan = $config->returnValue("vif $vif vlan");
    $vlan = $vif if !defined($vlan);
    my $inner_vlan = $config->returnValue("vif $vif inner-vlan");
    my $vif_name   = "$dev.$vif";
    $vif_name = "$dev.0$vlan" if ( defined($inner_vlan) );

    warn_failure("ip link set $vif_name type vlan proto $pvid")
        if ( -d "/sys/class/net/$vif_name" );
}

# Delete add or remove vifs of $dev
sub update_all_vifs {
    my ($dev) = @_;

    my $intf   = new Vyatta::Interface($dev);
    my $config = new Vyatta::Config( $intf->path() );

    # First Delete All devices
    for my $vif ( $config->listDeleted("vif") ) {
        del_vif( $vif, $dev, $intf, $config );
    }
    my ( @add_list, @change_list, @unchanged_list );
    for my $vif ( $config->listNodes("vif") ) {
        if ( $config->isAdded("vif $vif") ) {
            push( @add_list, ($vif) );
        } elsif ( $config->isChanged("vif $vif") ) {
            push( @change_list, ($vif) );
        } else {
            push( @unchanged_list, ($vif) );
        }
    }
    for my $vif (@change_list) {
        if ( $config->isChanged("vif $vif vlan") ) {
            update_vlan( $vif, $dev, $intf, $config );
        }
        if ( $config->isChanged("vif $vif inner-vlan") ) {
            update_ivlan( $vif, $dev, $intf, $config );
        }
    }
    for my $vif (@add_list) {
        add_vif( $vif, $dev, $intf, $config );
    }

    if ( $config->isChanged("vlan-protocol") ) {
        for my $vif (@unchanged_list) {
            update_pvid( $vif, $dev, $intf, $config );
        }
    }

}

sub add_vif {
    my ( $vif, $dev, $parent, $config ) = @_;
    die "Missing --dev argument\n" unless $dev;

    $parent = new Vyatta::Interface($dev) unless defined($parent);
    die "$dev is not a known interface type"
      unless defined($parent);

    my $name = "$dev.$vif";

    $config = new Vyatta::Config( $parent->path() ) unless defined($config);

    my $pvid = $config->returnValue("vlan-protocol");
    my $vlan = $config->returnValue("vif $vif vlan");
    $vlan = $vif if !defined($vlan);
    my $inner_vlan = $config->returnValue("vif $vif inner-vlan");

    $pvid = 0x8100 if ( !defined($pvid) );

    if ( defined($inner_vlan) ) {
        my $outer_vname = "$dev.0$vlan";
        if ( !-d "/sys/class/net/$outer_vname" ) {
            my $pvid_opt = "";

            $pvid_opt = "proto $pvid" if ( defined($pvid) );

            warn_failure(
"ip link add link $dev name $outer_vname type vlan id $vlan $pvid_opt"
            );
            if ( $dev =~ /^sw/ ) {
                Vyatta::Interface::add_interface_redirect( $outer_vname, 1 );
            }
            warn_failure("ip link set $outer_vname up") if ( $parent->up() );
        }
        $vlan = $inner_vlan  if defined($inner_vlan);
        $dev  = $outer_vname if defined($inner_vlan);
    }

    my $pvid_opt = "";
    $pvid_opt = "proto $pvid" if ( !defined($inner_vlan) && defined($pvid) );
    my $vopt = "";
    $vopt = "bridge_binding on" if $parent->type() eq "switch";

    warn_failure(
        "ip link add link $dev name $name type vlan id $vlan $pvid_opt $vopt");
    if ( $dev =~ /^sw/ ) {
        Vyatta::Interface::add_interface_redirect( $name, 1 );
    }

    Vyatta::Interface::vrf_bind_one($name);

    return 0;
}

sub get_vlan {
    my ($file) = @_;
    my $vid = 0;

    open( my $vlan_output, "<", "/proc/net/vlan/$file" )
      or die "can't open $file";

    while (<$vlan_output>) {
        / VID: ([^ ]+) / and $vid = $1, last;
    }
    $vid =~ s/\s+$//;
    return $vid;
}

sub update_vlan {
    my ( $vif, $dev, $parent, $config ) = @_;
    die "Missing --dev argument\n" unless $dev;

    $parent = new Vyatta::Interface($dev) unless defined($parent);
    die "$dev is not a known interface type"
      unless defined($parent);

    $config = new Vyatta::Config( $parent->path() ) unless defined($config);
    my $vlan = $config->returnValue("vif $vif vlan");
    $vlan = $vif unless ( defined($vlan) );

    my $name           = "$dev.$vif";
    my $inner_vlan     = $config->returnValue("vif $vif inner-vlan");
    my $old_inner_vlan = $config->returnOrigValue("vif $vif inner-vlan");
    my $old_vlan       = $config->returnOrigValue("vif $vif vlan");
    $old_vlan = $vif unless ( defined($old_vlan) );

    # This function gets called for both vif update and vif
    # creation(if vlan-id option is specified). Given that
    # vlan is optional in case of single vlan vif, this
    # function gets called when,
    # 1) Single vlan vif
    # 1.1) vif creation when vlan-id is specified.
    # 1.2) vlan change from vif-id to a configured vlan-id,
    #      but the vlan-id is the same as the vif-id
    # 1.3) vlan change from vif-id to a configured vlan-id,
    #      but vlan-id is different from vif-id
    # 1.4) vlan change from previously configured vlan-id to
    #      a new value
    # 1.4) vlan change from previously configured vlan-id to
    #      vif-id
    # 2) QinQ
    # 2.1) vif creation.
    # 2.2) vlan-id change.
    # 3) Vif change from single vlan to QinQ
    # 3.1) previously vlan-id was not specified, but the new
    #      vlan-id is the same as the vif-id
    # 3.2) previously vlan-id was not specified, but the new
    #      vlan-id is different the vif-id
    # 3.3) previously vlan-id was specified with a different value
    # 4) Vif change from QinQ to single vlan,
    # 4.1) new vlan-id is the same as the old and vlan-id is
    #      specified.
    # 4.2) new vlan-id is the same as the old and vlan-id is
    #      not specified (using vif-id).
    # 4.3) new vlan-id is different from the old and vlan-id is
    #      specified.
    # 4.3) new vlan-id is different from the old and vlan-id is
    #      not specified (using vif-id).
    #
    # We would need to prevent 1.1), 1.2), 2.1), 3.1), 4.1), 4.2) from
    # entering this function since otherwise, ip link cmd would
    # throw out errors.

    # case 1)
    my $curr_single_vlan = "";
    $curr_single_vlan = get_vlan($name)
      if ( !defined($old_inner_vlan) && !defined($inner_vlan) );
    return 0
      if ( !defined($old_inner_vlan)
        && !defined($inner_vlan)
        && "$vlan" eq $curr_single_vlan );

    # case 2) && case 3)
    my $curr_qinq_vlan = "";
    if ( ( -d "/sys/class/net/$dev.0$vlan" ) ) {
        $curr_qinq_vlan = get_vlan("$dev.0$vlan")
          if ( !defined($old_inner_vlan) && defined($inner_vlan) );
    } else {
        $curr_qinq_vlan = get_vlan("$dev.$vlan")
          if (!defined($old_inner_vlan)
            && defined($inner_vlan)
            && ( -d "/sys/class/net/$dev.$vlan" ) );
    }
    return 0
      if (!defined($old_inner_vlan)
        && defined($inner_vlan)
        && "$vlan" eq $curr_qinq_vlan );

    # case 4)
    return 0
      if ( defined($old_inner_vlan)
        && !defined($inner_vlan)
        && "$vlan" eq $curr_single_vlan );

    my $proto_opt = "";
    my $old_name  = "$dev.$vif";
    $old_name = "$dev.0$old_vlan" if ( defined($inner_vlan) );
    my $tpid     = $config->returnValue("vlan-protocol");
    $tpid = 0x8100 unless defined($tpid);
    $proto_opt = "proto $tpid";
    my $old_tpid = $config->returnOrigValue("vlan-protocol");

    $name = "$dev.0$vlan" if ( defined($inner_vlan) );

    if ( !-d "/sys/class/net/$name" || !defined($inner_vlan) ) {
        warn_failure("ip link set dev $old_name down")
          if ( -d "/sys/class/net/$old_name" );
        warn_failure("ip link set dev $old_name name $name")
          if ( -d "/sys/class/net/$old_name" );

        warn_failure("ip link set dev $name type vlan id $vlan $proto_opt")
          if ( ( -d "/sys/class/net/$name" )
            && defined($old_vlan)
            && ( $old_vlan != $vlan ) );
        warn_failure("ip link set dev $name up")
          if ( $parent->up() );
    } else {

        # Handle the case where the new vlan being set
        # can already exist for another vif as well.
        my $this_dev = new Vyatta::Interface( $dev . $vif );
        die "$dev.$vif is not a known interface type"
          unless defined($this_dev);

        if ( $this_dev->up() ) {
            warn_failure("ip link set $dev.$vif down");
            warn_failure("ip link set link $name $dev.$vif type vlan");
            warn_failure("ip link set $dev.$vif up");
        } else {
            warn_failure("ip link set link $name $dev.$vif type vlan");
        }
    }

    return 0;
}

sub update_ivlan {
    my ( $vif, $dev, $parent, $config ) = @_;
    die "Missing --dev argument\n" unless $dev;

    $parent = new Vyatta::Interface($dev) unless defined($parent);
    die "$dev is not a known interface type"
      unless defined($parent);

    $config = new Vyatta::Config( $parent->path() ) unless defined($config);
    my $vlan = $config->returnValue("vif $vif vlan");
    $vlan = $vif unless ( defined($vlan) );
    my $old_vlan = $config->returnOrigValue("vif $vif vlan");
    $old_vlan = $vif unless ( defined($old_vlan) );
    my $inner_vlan     = $config->returnValue("vif $vif inner-vlan");
    my $old_inner_vlan = $config->returnOrigValue("vif $vif inner-vlan");

    return 0
      unless ( defined($old_inner_vlan)
        || ( !-d "/sys/class/net/$dev.0$vlan" ) );

    my $inner_name = "$dev.$vif";
    my $outer_name = "$dev.0$old_vlan";
    my $pvid       = $config->returnValue("vlan-protocol");
    $pvid = 0x8100 unless defined($pvid);
    my $proto_opt = "proto $pvid";

    # 1) inner vlan change
    # 2) vlan only => vlan + inner vlan
    # 3) vlan + inner vlan => vlan only
    if ( defined($inner_vlan) ) {
        if ( !defined($old_inner_vlan) ) {

            # 2)
            $outer_name = "$dev.0$vlan";
            warn_failure(
                "ip link set dev $inner_name type vlan id 0 proto 0x8100")
              if ( -d "/sys/class/net/$inner_name" );
            warn_failure(
"ip link add link $dev name $outer_name type vlan id $old_vlan $proto_opt"
            ) if ( -d "/sys/class/net/$dev" );
            warn_failure(
                "ip link set dev $inner_name link $outer_name type vlan")
              if ( -d "/sys/class/net/$inner_name" );
            warn_failure("ip link set dev $inner_name type vlan id $inner_vlan")
              if ( -d "/sys/class/net/$inner_name" );

            if ( $parent->up() ) {
                warn_failure("ip link set dev $outer_name up");
            }
        } else {

            # 1)
            warn_failure("ip link set $inner_name type vlan id $inner_vlan")
              if ( ( $inner_vlan ne $old_inner_vlan )
                && -d "/sys/class/net/$inner_name" );
        }
    } else {

        # 3)
        if ( defined($old_inner_vlan) ) {
            warn_failure("ip link set dev $inner_name type vlan id 0")
              if ( -d "/sys/class/net/$inner_name" );
            warn_failure("ip link set dev $inner_name link $dev type vlan")
              if ( -d "/sys/class/net/$inner_name" );
            my $used = 0;
            if ( defined($outer_name) && -d "/sys/class/net/$outer_name" ) {
                $used =
                  grep { /^upper_/ } read_dir("/sys/class/net/$outer_name");

              # delete the outer vlan interface only if no inner vlan is defined
                warn_failure("ip link delete $outer_name") if !$used;
            }
            warn_failure(
                "ip link set dev $inner_name type vlan id $old_vlan $proto_opt"
            ) if ( -d "/sys/class/net/$inner_name" && !$used );
        }

        $outer_name = $inner_name;
    }

    return 0;
}

sub del_vif {
    my ( $vif, $dev, $parent, $config ) = @_;
    die "Missing --dev argument\n" unless $dev;

    $parent = new Vyatta::Interface($dev) unless defined $parent;
    die "$dev is not a known interface type"
      unless defined($parent);

    my $name = "$dev.$vif";

    warn_failure("ip link delete $name")
      if ( -d "/sys/class/net/$name" );

    $config = new Vyatta::Config( $parent->path() ) unless defined($config);
    my $vlan       = $config->returnOrigValue("vif $vif vlan");
    my $inner_vlan = $config->returnOrigValue("vif $vif inner-vlan");
    my $outer_vname;
    $outer_vname = "$dev.0$vlan" if defined($inner_vlan);

    $vlan = $vif unless ( defined($vlan) );

    if ( defined($outer_vname) && -d "/sys/class/net/$outer_vname" ) {
        my $used = grep { /^upper_/ } read_dir("/sys/class/net/$outer_vname");

        # delete the outer vlan interface only if no inner vlan is defined
        warn_failure("ip link delete $outer_vname") if !$used;
    }

    return 0;
}

1;
