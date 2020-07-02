#! /usr/bin/perl -w

# Copyright (c) 2018-2019, AT&T Intellectual Property. All rights reserved.
#

# Copyright (c) 2014-2017, Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: GPL-2.0-only

# This script is registered as a deferred action for the creation
# of tunnel interfaces. It can be invoked either from configd as part
# of the deferred action, or directly from DHCP callback, offering
# support for DHCP (physical) interfaces as local tunnel underlay
# interfaces. When called from DHCP context, the script will not have
# a socket open to configd, so any other scripts invoked within should
# not try to open or read the config in the DEFERRED_CREATE mode. When
# called from configd, it does have a socket open to configd and can
# read the system configuration. The script should do the bare minimum
# needed to create/handle address change on the tunnel interfaces, leaving
# the rest to the CLI walk from IFMGR, letting it invoke the CLI action
# scripts which take care of setting up attributes on the interface.

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Address;
use File::Temp qw(tempfile);
use Net::IP;
use Module::Load::Conditional qw[can_load];
use Vyatta::Interface qw(add_interface_redirect);

my $vrf_available = can_load(
    modules  => { "Vyatta::VrfManager" => undef },
    autoload => "true"
);

sub opennhrp_is_running {
    return ( qx(pgrep opennhrp) ne "" );
}

sub update_nhrp_triggers {
    my ( $nhrp, $tunnel, $local_addr, $tunnel_exists, $address_transition ) =
      @_;
    if ( $nhrp eq "NHRP" ) {
        if ( defined($address_transition) ) {
            system(
"/opt/vyatta/sbin/vyatta-update-nhrp.pl --tun $tunnel --local_addr $local_addr --update_iptables"
            );
        }
    }
}

sub update_ip_rule_on_tunnel_create {
    my ( $tunnel, $old_encap, $new_encap ) = @_;

    if ( defined($old_encap)
        && index( $old_encap, "gre" ) == -1 )
    {
        system("ip rule del iif $tunnel lookup 230");
    }
    if ( index( $new_encap, "gre" ) == -1 ) {
        system("ip rule add iif $tunnel lookup 230");
    }
}

sub create_vxlan_interface {
    my ( $name, $encap, $vxl_id, $local, $remote, $grp_addr, $t_vrf, $params )
      = @_;
    my ( $port, $gpe, $remote_str );

    if ( $encap eq 'vxlan' ) {
        $port = 4789;
        $gpe  = "";
    } else {
        $port = 4790;
        $gpe  = 'gpe';
    }
    if ( $t_vrf ne "" && $vrf_available ) {
        $t_vrf = " dev vrf$t_vrf";
    }

    if ( $remote ne "" ) {
        $remote_str = "remote $remote";
    } else {
        my ( $if_name, $link_up, $tentative ) =
          Vyatta::Address::get_interface($local);
        die "Local interface not defined" unless defined($$if_name);
        $remote_str = "group $grp_addr dev $$if_name";
    }
    if ( !defined($params) ) {
        $params = "";
    }
    my $cmd =
"ip link add $name type vxlan id $vxl_id $gpe local $local $remote_str dstport $port $t_vrf $params";
    system("$cmd");
}

sub create_or_modify_tunnel {

    my $tunnel_exists = undef;
    my (
        $tunnel,             $old_encap,           $encap,
        $local_addr,         $remote_ip,           $nhrp,
        $address_transition, $recreate_transition, $key_value,
        $intf,               $vxlan_id,            $pmtudisc_dis,
        $ttl,                $tos,                 $t_vrf,
        $grp_addr,           $params
    ) = @_;
    my $tunnel_verb = 'add';

    my $PMTUDISC = "";
    my $TTL      = "";
    my $TOS;
    my $TYPE;
    my $ARP = "";

    # Not a VXLAN tunnel type
    if ( index( $encap, "vxlan" ) != -1 ) {
        if ( defined($pmtudisc_dis) ) {
            $PMTUDISC = "nopmtudisc";
        } else {
            $PMTUDISC = "pmtudisc";
        }
    }
    if ( ( $PMTUDISC ne "nopmtudisc" ) && !defined($ttl) ) {
        $PMTUDISC = "";
        $TTL      = "ttl 255";
    }
    if ( !defined($tos) ) {
        $TOS = "tos inherit";
    } else {
        $TOS = "tos $tos";
    }

    if ( -d "/sys/class/net/$tunnel" ) {
        if ($recreate_transition) {

            # Can't modify the encap so delete and re-create
            system("ip link del $tunnel");
        } else {
            $tunnel_exists = 1;
            $tunnel_verb   = 'set';
        }
    }

    if ( $encap eq "gre-multipoint" ) {
        $TYPE = "gre";
        $ARP  = "arp on";
        if ( defined($key_value) ) {
            system(
"ip link $tunnel_verb $tunnel type gre local $local_addr key $key_value"
            );
        } else {
            system("ip link $tunnel_verb $tunnel type gre local $local_addr");
        }
        update_nhrp_triggers( $nhrp, $tunnel,
            $local_addr, undef, $address_transition );
        if ( $tunnel_verb eq "add" ) {
            system("invoke-rc.d opennhrp start");
            system("ip link set $tunnel $ARP");
        }
    } elsif ( $encap eq "gre-bridge" ) {
        $TYPE = "gretap";
        system(
"ip link $tunnel_verb $tunnel type gretap local $local_addr remote $remote_ip"
        );
    } elsif ( $encap eq "vxlan" || $encap eq "vxlan-gpe" ) {
        if ( defined($tunnel_exists) ) {
            system("ip link del $tunnel");
        }
        $TYPE = "vxlan";
        create_vxlan_interface( $tunnel, $encap, $vxlan_id,
            $local_addr, $remote_ip, $grp_addr, $t_vrf, $params );
    } elsif ( $encap eq "ipip6" || $encap eq "ip6ip6" ) {
        $TYPE = "ip6tnl";
        system(
"ip link $tunnel_verb $tunnel type ip6tnl mode $encap local $local_addr remote $remote_ip"
        );
        if ( defined($tunnel_exists) ) {
            my $procdir = "/proc/sys/net/ipv6/conf";
            system(
                "ip link set $tunnel arp on &&
 cp $procdir/default/accept_dad $procdir/$tunnel/accept_dad"
            );
        }
    } else {
        $TYPE = $encap;
        if ( defined($key_value) ) {
            system(
"ip link $tunnel_verb $tunnel type $encap local $local_addr remote $remote_ip key $key_value"
            );
        } else {
            system(
"ip link $tunnel_verb $tunnel type $encap local $local_addr remote $remote_ip"
            );
        }
    }
    if ( $encap eq "gre-multipoint" ) {
        if ( opennhrp_is_running() && ( $nhrp eq "NHRP" ) ) {
            system("opennhrpctl purge dev $tunnel");
        }
    }

    if ( $encap eq "ip6gre" ) {
        add_interface_redirect( $tunnel, 1 );
    }
    system("ip link set $tunnel type $TYPE $PMTUDISC $TTL $TOS");
    update_ip_rule_on_tunnel_create( $tunnel, $old_encap, $encap );
}

sub parse_metafile_create_tunnel {

    my $metafile            = undef;
    my $old_encap           = undef;
    my $encap               = undef;
    my $tunnel              = undef;
    my $remote_ip           = undef;
    my $local_intf          = undef;
    my $nhrp                = undef;
    my $key_value           = undef;
    my $vxlan_id            = undef;
    my $address_transition  = 1;
    my $recreate_transition = undef;
    my $pmtudisc_dis        = undef;
    my $ttl                 = undef;
    my $tos                 = undef;
    my ( $intf, $local_addr ) = @_;

    open( $metafile, '<', "/var/run/.$intf.tunnel_deferred.txt" )
      || die "Could not open metadata file for $intf";

    if ( defined($metafile) ) {
        while (<$metafile>) {
            chomp;
            (
                $tunnel,       $nhrp,      $local_intf,
                $encap,        $remote_ip, $key_value,
                $pmtudisc_dis, $ttl,       $tos
            ) = split(':');

            if (   defined($local_intf)
                && defined($local_addr)
                && defined($tunnel)
                && defined($encap)
                && ( $local_intf eq $intf ) )
            {
                create_or_modify_tunnel(
                    $tunnel,             $old_encap,
                    $encap,              $local_addr,
                    $remote_ip,          $nhrp,
                    $address_transition, $recreate_transition,
                    $key_value,          $intf,
                    $vxlan_id,           $pmtudisc_dis,
                    $ttl,                $tos
                );
            } else {
                print STDERR
                  "\nUnable to create/modify tunnel on interface $intf\n";
            }
        }
    }

    if ( defined($metafile) ) {
        close($metafile);
    }
}

sub get_current_ip_address {

    my ($local_intf) = @_;

    my $if_line = qx(ip addr show $local_intf);
    if ( $if_line =~ /inet (\d+\.\d+\.\d+\.\d+)/ ) {
        return $1;
    }
    return undef;
}

sub def_or_empty_str {
    my ($str) = @_;

    if ( !defined($str) ) {
        return "";
    }

    return $str;
}

sub tunnel_param_changed {
    my ( $cfg, $tunnel ) = @_;
    my ( $changed, $params );

    my $old_grp_addr = def_or_empty_str(
        $cfg->returnOrigValue("$tunnel transport multicast-group") );
    my $grp_addr = def_or_empty_str(
        $cfg->returnValue("$tunnel transport multicast-group") );
    my $old_flowlabel = def_or_empty_str(
        $cfg->returnOrigValue("$tunnel parameters ipv6 flowlabel") );
    my $flowlabel = def_or_empty_str(
        $cfg->returnValue("$tunnel parameters ipv6 flowlabel") );
    my $old_tclass = def_or_empty_str(
        $cfg->returnOrigValue("$tunnel parameters ipv6 tclass") );
    my $tclass =
      def_or_empty_str( $cfg->returnValue("$tunnel parameters ipv6 tclass") );
    my $old_hoplimit = def_or_empty_str(
        $cfg->returnOrigValue("$tunnel parameters ipv6 hoplimit") );
    my $hoplimit =
      def_or_empty_str( $cfg->returnValue("$tunnel parameters ipv6 hoplimit") );

    if (   $old_grp_addr ne $grp_addr
        || $old_flowlabel ne $flowlabel
        || $old_tclass ne $tclass
        || $old_hoplimit ne $hoplimit )
    {
        $changed = 1;
    } else {
        $changed = 0;
    }

    $params = "";
    if ( $flowlabel ne "" ) {
        $params = $params . " flowlabel $flowlabel";
    }

    return ( $changed, $params );
}

sub cmp_maybe_undef {
    my ( $str1, $str2 ) = @_;

    return 1
      if ( ( !defined($str1) && !defined($str2) )
        || ( defined($str1) && defined($str2) && $str1 eq $str2 ) );
    return 0;
}

sub create_tunnel_now_or_defer {

    my ($tunnel) = @_;

    # Register the interface to be managed with ifmgrd

    system("ifmgrctl register $tunnel") == 0
      or exit 1;

    my $cfg = new Vyatta::Config("interfaces tunnel");

    if ( !defined($cfg) ) {
        die "\nCould not open config for Tunnel $tunnel";
    }

    my $encap          = $cfg->returnValue("$tunnel encapsulation");
    my $old_encap      = $cfg->returnOrigValue("$tunnel encapsulation");
    my $remote_ip      = $cfg->returnValue("$tunnel remote-ip");
    my $old_remote_ip  = $cfg->returnOrigValue("$tunnel remote-ip");
    my $local_addr     = $cfg->returnValue("$tunnel local-ip");
    my $old_local_addr = $cfg->returnOrigValue("$tunnel local-ip");
    my $grp_addr       = $cfg->returnValue("$tunnel transport multicast-group");
    my $old_grp_addr =
      $cfg->returnOrigValue("$tunnel transport multicast-group");
    my $local_intf     = $cfg->returnValue("$tunnel local-interface");
    my $old_local_intf = $cfg->returnOrigValue("$tunnel local-interface");
    my $nhrp           = $cfg->exists("$tunnel nhrp");
    my $key_value      = $cfg->returnValue("$tunnel parameters ip key");
    my $old_key_value  = $cfg->returnOrigValue("$tunnel parameters ip key");
    my $vxlan_id = def_or_empty_str( $cfg->returnValue("$tunnel vxlan-id") );
    my $old_vxlan_id =
      def_or_empty_str( $cfg->returnOrigValue("$tunnel vxlan-id") );
    my $t_vrf_name = def_or_empty_str(
        $cfg->returnValue("$tunnel transport routing-instance") );
    my $old_t_vrf_name = def_or_empty_str(
        $cfg->returnOrigValue("$tunnel transport routing-instance") );
    my $pmtudisc_dis = $cfg->returnValue("$tunnel path-mtu-discovery-disable");
    my $ttl          = $cfg->returnValue("$tunnel parameters ip ttl");
    my $tos          = $cfg->returnValue("$tunnel parameters ip tos");

    my $meta_file_exists = undef;
    my $outhandle        = undef;
    my %tunnel2metadata;
    my @temp;
    my $tmp                 = undef;
    my $transition          = undef;
    my $address_transition  = undef;
    my $recreate_transition = undef;

    my $ip = new Net::IP($local_addr);
    if ( ( $ip->version() eq "6" ) and ( $encap eq "gre" ) ) {
        $encap = "ip6gre";
    }

    if ( defined($nhrp) ) {

        #Does nhrp exists in the config? Convert it to a string, regardless.
        $nhrp = "NHRP";
    } else {
        $nhrp = "NOTNHRP";
    }

    my ( $changed, $params ) = tunnel_param_changed( $cfg, $tunnel );

    # Linux 4.12 doesn't support modification of a GRE interface from
    # non-key to key and vice-versa as it doesn't copy the flags
    # netlink attributes on a modify. In addition, iproute 4.12
    # doesn't allow specifying a nokey attribute so it isn't possible
    # to ask for a transition from key to non-key.
    $recreate_transition = 1
      if ( !cmp_maybe_undef( $old_encap, $encap )
        || !cmp_maybe_undef( $old_key_value, $key_value ) );
    $transition = 1
      if ( !cmp_maybe_undef( $old_local_addr, $local_addr )
        || !cmp_maybe_undef( $old_local_intf, $local_intf )
        || !cmp_maybe_undef( $old_remote_ip,  $remote_ip )
        || ( defined($recreate_transition) )
        || ( $vxlan_id ne $old_vxlan_id )
        || ( $t_vrf_name ne $old_t_vrf_name )
        || ( $encap eq 'vxlan' && $changed ) );
    $address_transition = 1
      if (
           ( defined($old_local_addr) && defined($local_intf) )
        || ( defined($old_local_intf) && defined($local_addr) )
        || (   defined($old_local_addr)
            && defined($local_addr)
            && ( $old_local_addr ne $local_addr ) )
        || (   defined($old_local_intf)
            && defined($local_intf)
            && ( $old_local_intf ne $local_intf ) )
      );

    if ( !defined($local_addr) && defined($local_intf) ) {

        # See if any prior metadata exists,
        # this will be removed later if local-ip was used.
        $meta_file_exists =
          open( $outhandle, '<', "/var/run/.$local_intf.tunnel_deferred.txt" );
        if ( defined($meta_file_exists) ) {

            # Read the existing metadata file into a hash, if it exists
            # This is needed so that data on other tunnels can be preserved
            # while the entry of this tunnel alone is updated.
            while (<$outhandle>) {
                chomp;
                ( $tmp, @temp ) = split(':');
                $tunnel2metadata{$tmp} = $_;
            }
            close($outhandle);
        }

        $local_addr = get_current_ip_address($local_intf);
    } elsif ( !defined($local_addr) ) {
        die "Tunnel $tunnel - could not determine local IP address\n";
    }

    # Write meta file if local interface was specified. Needed for DHCP update.
    # Write into a temp file and move it into the right location.
    # regenerate
    if ( defined($local_intf) ) {
        $outhandle = File::Temp->new( UNLINK => 0, SUFFIX => '.txt' );
        my $tmpname   = $outhandle->filename;
        my $outstring = '';
        foreach ( sort keys %tunnel2metadata ) {
            unless ( $_ eq $tunnel ) {
                $outstring .= $tunnel2metadata{$_} . "\n";
            }
        }
        $outstring .= join(
            ":",
            grep ( $_,
                (
                    $tunnel,       $nhrp,      $local_intf,
                    $encap,        $remote_ip, $key_value,
                    $pmtudisc_dis, $ttl,       $tos
                ) )
        ) . "\n";
        print $outhandle $outstring;
        chmod( 755, $outhandle );
        close($outhandle);
        system( "cp", $tmpname, "/var/run/.$local_intf.tunnel_deferred.txt" )
          == 0
          or die "Tunnel $tunnel Intf $local_intf Could not copy metadata file";

       #To take care of a race condition where DHCP ran simultaneously with this
       #script, but completed before the meta-file was written, re-check if the
       # interface has an address now, and if so, create the tunnel right now.
        if ( !defined($local_addr) ) {
            $local_addr = get_current_ip_address($local_intf);
        }

       # if local tunnel address is known, parse meta-file and create tunnel now
        if ( defined($local_addr) && defined($transition) ) {
            create_or_modify_tunnel(
                $tunnel,             $old_encap,
                $encap,              $local_addr,
                $remote_ip,          $nhrp,
                $address_transition, $recreate_transition,
                $key_value,          $local_intf,
                $vxlan_id,           $pmtudisc_dis,
                $ttl,                $tos,
                $t_vrf_name,         $grp_addr,
                $params
            );
        }
    } else {
        if ( defined($local_addr) && defined($tunnel) && defined($encap) ) {
            if ( defined($transition) ) {
                create_or_modify_tunnel(
                    $tunnel,             $old_encap,
                    $encap,              $local_addr,
                    $remote_ip,          $nhrp,
                    $address_transition, $recreate_transition,
                    $key_value,          $local_intf,
                    $vxlan_id,           $pmtudisc_dis,
                    $ttl,                $tos,
                    $t_vrf_name,         $grp_addr,
                    $params
                );
            }
        }
    }
}

sub delete_tunnel {
    my ($tunnel) = @_;

    my $cfg = new Vyatta::Config("interfaces tunnel");

    if ( !defined($cfg) ) {
        die "\nCould not open config for Tunnel $tunnel for delete";
    }

    my $encap = $cfg->returnOrigValue("$tunnel encapsulation");

    system("ip link set $tunnel down");
    system("ip link delete $tunnel");
    if ( index( $encap, "gre" ) == -1
        && -e "/sys/class/net/.spathintf" )
    {
        system("ip rule del iif $tunnel lookup 230");
    }
}

my ( $commit_action, @other_params ) = @ARGV;

if ( $commit_action eq "DEFERRED_CREATE" ) {
    parse_metafile_create_tunnel(@other_params);
} elsif ( $commit_action eq "DELETE" ) {
    delete_tunnel(@other_params);
} elsif ( $commit_action eq "SET" or $commit_action eq "ACTIVE" ) {
    create_tunnel_now_or_defer(@other_params);
} else {
    die "Invalid deferred action for tunnel specified\n";
}

exit(0);
