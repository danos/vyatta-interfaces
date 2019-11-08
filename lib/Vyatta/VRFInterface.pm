# Author: Nachiketa Prachanda <nprachan@brocade.com>
# Date: Mar 2016
# Description: Modules for VRF related Interface config.
#
# **** License ****
# Copyright (c) 2018, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
# **** End License ****
package Vyatta::VRFInterface;

use strict;
use warnings;
use Vyatta::VrfManager qw(update_interface_vrf $VRFNAME_DEFAULT);

use Exporter qw(import);
our @EXPORT_OK = qw(vrf_bind_one);

# Only use this for binding an interface during create
sub vrf_bind_one {
    require Vyatta::Interface;
    my $ifname = shift;
    my $intf   = Vyatta::Interface->new($ifname);
    return unless ( defined($intf) && $intf->exists() );
    my $vrf    = Vyatta::Interface::get_interface_rd($ifname);
    $vrf = $VRFNAME_DEFAULT if !defined($vrf);

    return
      unless ( defined($vrf)
        && $intf->vrf() ne $vrf );

    return update_interface_vrf( $ifname, $vrf, $intf->up() );
}

1;
