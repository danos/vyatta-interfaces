# Copyright (c) 2019, AT&T Intellectual Property.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

import configparser

def get_switch_cfg():
    SWITCH_CONF = '/run/vyatta/switch.conf'

    class switchConfig:
        def __init__(self, config):
            self.config = config

        def hwSwitchCount(self):
            try:
                return int(self.config['Hardware']['hwSwitchCount'])
            except:
                return 0

        def hwSwitchId(self, id):
            try:
                return int(self.config['Hardware']['hwSwitch{}.id'.format(id)])
            except:
                return None

        def hwSwitchIntfs(self, id):
            try:
                return self.config['Hardware']['hwSwitch{}.intfs'.format(id)].split(',')
            except:
                return None

    try:
        config = configparser.ConfigParser()
        config.read(SWITCH_CONF)
        return switchConfig(config)
    except:
        return None

def is_switch_port(interface_name):
    switch = get_switch_cfg()
    if not switch:
        return False
    for id in range(0, switch.hwSwitchCount()):
        if interface_name in switch.hwSwitchIntfs(id):
            return True
    return False
