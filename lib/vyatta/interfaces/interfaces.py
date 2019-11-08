#!/usr/bin/env python3
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

from vyatta import configd
import collections

_ifconfig_t = collections.namedtuple("ifconfig", "type key")


"""
Return a dictionary mapping each interface to its type and key.
Return an empty dictionary if there are no interfaces.
Return None if the configd session can't be established.
"""


def getInterfaceConfig():
    try:
        client = configd.Client()
    except Exception as exc:
        print("Cannot establish client session: '{}'".format(str(exc).strip()))
        return None

    if (not client.node_exists(client.AUTO, "interfaces")):
        return None

    ifconfig = {}
    iflist = client.tree_get_dict("interfaces")['interfaces']
    for iftype in iflist:
        tmpl = client.template_get(["interfaces", iftype])
        tagtype = tmpl["key"]
        ifnames = [x[tagtype] for x in iflist[iftype] if x[tagtype]]
        ifconfig.update({intf: _ifconfig_t(type=iftype, key=tagtype)
                        for intf in ifnames})

    return ifconfig
