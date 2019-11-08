# Copyright (c) 2017-2019, AT&T Intellectual Property.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::PPP;

use strict;
use warnings;

use base qw(Exporter);
use Vyatta::Configd;
use Vyatta::VPlaned;
use File::Path qw(make_path);
use Template;

use vyatta::proto::PPPOEConfig;

our @EXPORT_OK =
  qw(ppp_update_config ppp_remove_config ppp_call ppp_hangup ppp_dp_ses_delete ppp_dp_ses_set add_ecmp_rule);

sub update_ppp_systemd_env {
    my ( $ifname, $pppname ) = @_;
    make_path("/run/pppoe/");
    open( my $fh, '>', "/run/pppoe/pppoe-$pppname.env" )
      or die "Could not open pppoe env file\n";
    print $fh "ifname=$ifname\n";
    print $fh "pppname=$pppname\n";
    close($fh);
}

sub ppp_remove_config {
    my ($pppname) = @_;
    unlink "/etc/ppp/peers/pppoe-$pppname";
    unlink "/run/ppp/pppoe-$pppname.env";
}

# Builds pppd acceptable peer file in
# /etc/ppp/peers
#
sub ppp_update_config {
    my ($pppname) = @_;
    my $config = Vyatta::Configd::Client->new();

    die "Config not found"
      unless defined($config);

    my $db = $Vyatta::Configd::Client::AUTO;
    return unless $config->node_exists( $db, "interfaces pppoe $pppname" );

    # Build tree config hash
    #
    my $tree = $config->tree_get_hash("interfaces pppoe $pppname");
    $tree->{'pppname'} = $pppname;

    my $ppp_session_name = "pppoe-${pppname}";
    $tree->{'logfile'} = "/var/log/vyatta/$ppp_session_name";

    # Delete whatever pppoe config is already there.
    unlink "/etc/ppp/peers/$ppp_session_name";

    # Fill in yang type empties as they show up as ex:
    # $tree->{'default-route'} = undef
    foreach my $key ( keys %{$tree} ) {
        $tree->{$key} = 1 unless defined $tree->{$key};
    }

    # Fill out the template and write to file
    my $provider_file = "/etc/ppp/peers/$ppp_session_name";
    open( my $fh, '<', '/opt/vyatta/etc/ppp/peers/pppoe-provider-template' );
    my $template = Template->new();
    my %tree_in = ( 'cfg' => $tree );
    $template->process( $fh, \%tree_in, $provider_file )
      or die("Could not fill out provider template\n");
    close($fh);

    # Build systemd environment
    update_ppp_systemd_env( $tree->{'interface'}, $tree->{'pppname'} );
}

sub add_ecmp_rule {
    my ($ip)      = @_;
    my $config    = Vyatta::Configd::Client->new();
    my $db        = $Vyatta::Configd::Client::AUTO;
    my $interface = $config->tree_get_full_hash("interfaces pppoe");
    my $params    = '';
    foreach my $i ( @{ $interface->{'pppoe'} } ) {
        my $r = `ip addr show $i->{'ifname'} | grep 'inet'`;
        if ( $r =~ m/peer (\S+)\// ) {
            $r      = $1;
            $params = $params . "nexthop dev $i->{'ifname'} "
              if ( $r eq $ip );
        }
    }
    if ( $params eq '' ) {
        return;
    }
    my $IP = $ENV{IPREMOTE};
    my $ip_cmd = "ip route replace ${IP}/32 $params";
    system("$ip_cmd");
}

# Initiate a call out according to a certain PPPoE interface name.
# Configs are found in /etc/ppp/peers/pppoe-*
#
sub ppp_call {
    my ($pppname) = @_;
    return unless defined $pppname;

    # Check if config file exists
    return
      unless ( -e "/etc/ppp/peers/pppoe-$pppname" );

    # Start pppoe client
    # Check the journal for log messages
    system("systemctl restart vyatta-pppoe\@${pppname} &>/dev/null");
}

# Hang up according to PPPoE interface name.
#
sub ppp_hangup {
    my ($pppname) = @_;
    return unless defined $pppname;

    # Check the journal for log messages
    system("systemctl stop vyatta-pppoe\@${pppname} &>/dev/null");
}

# Configure (SET) PPPoE session ID in remote dataplane via
# cstore API
#
sub ppp_dp_ses_set {
    my ( $ifname, $device, $session, $myeth, $peereth ) = @_;
    if ( @_ < 5 ) {
        die "Missing config options\n";
    }

    my $cstore = new Vyatta::VPlaned;
    return unless defined $cstore;

    my $pppoe = PPPOEConfig->new({
	pppname    => $ifname,
	undername  => $device,
	session    => $session,
	ether      => $myeth,
	peer_ether => $peereth,
				 });

    $cstore->store_pb(
	"pppoe",
	$pppoe,
	"vyatta:pppoe",
	$ifname,
	"SET");
}

# Unconfigure (DELETE) PPPoE session ID to remote dataplane
# via cstore API
#
sub ppp_dp_ses_delete {
    my ( $ifname, $device, $session, $myeth, $peereth ) = @_;
    if ( @_ < 5 ) {
        die "Missing config options\n";
    }

    my $cstore = new Vyatta::VPlaned;
    return unless defined $cstore;

    my $pppoe = PPPOEConfig->new({
	pppname    => $ifname,
	undername  => $device,
	session    => $session,
	ether      => $myeth,
	peer_ether => $peereth,
				 });

    $cstore->store_pb(
	"pppoe",
	$pppoe,
	"pppoe",
	$ifname,
	"DELETE");
}

