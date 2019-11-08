#!/usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
#

package Vyatta::UnnumberedInterface;

use strict;
use warnings;
use Readonly;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Interface;
use Getopt::Long;
use Vyatta::Misc;

use base qw( Exporter );
our @EXPORT = qw(unnumbered_update_donor unnumbered_update);

# check_unnumbered_dependancy(ifihash, "donor")
# returns 1 if
#  u is an unnumbered interface with a "donor" as donor.
#  AND it doesn't have a preferred address
#  AND it isn't changed.
# When this functions returns true, we need to reapply the
# unnumbered interface to the system to reflect any changes to
# the loop back address.

sub is_unnumbered_dependent {
	my ($u, $dn, $ip) = @_;

	return unless $u->{'type'} eq 'dataplane';

	my $cfg = new Vyatta::Config(
		$u->{'path'} . " $ip unnumbered donor-interface");

	return ($cfg->exists($dn) &&
		not ($cfg->returnValue("$dn preferred-address") ||
			$cfg->isAdded($dn) || $cfg->isChanged($dn)));
}

sub apply_change {
    my ($dif, $ip, $args) = @_;

    my @fix_unnumbered = grep { is_unnumbered_dependent($_, $dif->name(), $ip) }
				(Vyatta::Interface::get_interfaces());

    my $cmd = "/opt/vyatta/sbin/vyatta-update-unnumbered.pl $args --dev=";
    foreach my $uif (@fix_unnumbered) {
        system($cmd . $uif->{'name'}) == 0
          or die "Cannot update unnumbered donors for $uif->{'name'}";
    }
}


sub unnumbered_update_donor {
    my ( $dev ) = @_;

    my $dif = new Vyatta::Interface($dev);
    die "Invalid device $dev\n" unless defined($dif);

    # We need to reapply unnumbered only if we have deleted
    # ipv4 addresses from an interface.
    # In case of additions we are not required to change the
    # unnumbered interfaces.

    my $cfg = new Vyatta::Config( $dif->path() );

    my @v4_addrs =
      grep { valid_ip_prefix($_) >= 1 } ( $cfg->returnValues("address") );
    my @del_v4_addrs =
      grep { valid_ip_prefix($_) >= 1 } ( $cfg->listDeleted("address") );
    if ( ( scalar(@v4_addrs) != 0 ) && ( scalar(@del_v4_addrs) != 0 ) ) {
        apply_change( $dif, "ip", "--force" );
    }

    my @v6_addrs =
      grep { valid_ipv6_prefix($_) >= 1 } ( $cfg->returnValues("address") );
    my @del_v6_addrs =
      grep { valid_ipv6_prefix($_) >= 1 } ( $cfg->listDeleted("address") );
    if ( ( scalar(@v6_addrs) != 0 ) && ( scalar(@del_v6_addrs) != 0 ) ) {
        apply_change( $dif, "ipv6", "--ipv6 --force" );
    }
}

sub unnumbered_update {
    my ( $dev, $ipv6, $force ) = @_;
    my $if = new Vyatta::Interface($dev);
    die "Invalid device $dev\n" unless defined($if);

    my $ip = defined($ipv6) ? "ipv6" : "ip";

    my $config = new Vyatta::Config($if->path()." $ip unnumbered donor-interface");

    if (scalar($config->listDeleted()) > 0) {
        system("/usr/bin/vtysh -c enable"
              ." -c \"configure terminal\""
              ." -c \"interface $dev\""
              ." -c \"no $ip unnumbered\"");
    }

    my @difs = $config->listNodes();
    exit 0 if (scalar(@difs) == 0);

    #config system ensures there is never more than one value in output of listNodes();
    my $dif = $difs[0];
    if ($force || $config->isAdded($dif) || $config->isChanged($dif)) {
        my $cmd = "/usr/bin/vtysh -c enable"
              ." -c \"configure terminal\""
              ." -c \"interface $dev\"";

        if ($force || ! $config->isAdded($dif)) {
            system ($cmd . " -c \"no $ip unnumbered\"");
        }

        my $paddr = $config->returnValue("$dif preferred-address");
        if (defined($paddr)) {
              $cmd = $cmd . " -c \"$ip unnumbered $dif $paddr\"";
        } else {
              $cmd = $cmd . " -c \"$ip unnumbered $dif\"";
        }
        system($cmd);
    }
}

1;
