#!/usr/bin/python3

# Copyright (c) 2019, AT&T Intellectual Property.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

import unittest

class DSCP:
    dsfield = { "default": 0,
                "cs0":   0,
                "cs1":   8,
                "cs2":  16,
                "cs3":  24,
                "cs4":  32,
                "cs5":  40,
                "cs6":  48,
                "cs7":  56,
                "af11": 10,
                "af12": 12,
                "af13": 14,
                "af21": 18,
                "af22": 20,
                "af23": 22,
                "af31": 26,
                "af32": 28,
                "af33": 30,
                "af41": 34,
                "af42": 36,
                "af43": 38,
                "ef":   46,
                "va":   44 }

    def __init__(self, dscp = None):
        if dscp is not None:
            self.dscp = self.str2dscp(dscp)

    def __repr__(self):
        return repr(self.dscp)

    def __int__(self):
        return self.dscp

    def __str__(self):
        return str(self.dscp)

    def dscp_lookup(self, dscp):
        """
        Convert a DSCP string to its decimal equivalent
        """
        if dscp.lower() in self.dsfield:
            return self.dsfield[dscp.lower()]
        return None

    def dscp_range(self, ranges):
        """
        Split comma separated list of ranges into values
        """
        dscp_list = list()
        for item in ranges.split(','):
            if item.find('-') > 0:
                begin, end = item.split('-')
                begin = self.str2dscp(begin)
                end = self.str2dscp(end)
                if end < begin:
                    return None
                for dscp in range(begin, end + 1):
                    dscp_list.append(dscp)
            else:
                dscp_list.append(self.str2dscp(item))
        return dscp_list

    def dscp_values(self):
        """
        Return a list of the possible DSCP strings
        """
        return self.dsfield.keys()

    def str2dscp(self, dscp):
        """
        Convert a DSCP string to its decimal equivalent
        """
        if dscp.lower() in self.dsfield:
            return self.dsfield[dscp.lower()]
        try:
            num = int(dscp, 0)
        except:
            raise ValueError("Can't convert \"{}\" to a valid DSCP".format(dscp))
        if num < 0 or num > 63:
            raise ValueError("Can't convert \"{}\" to a valid DSCP".format(dscp))
        return num

class DscpTestCase(unittest.TestCase):

    def test_string(self):
        self.assertTrue(str(DSCP("af33")) == "30")

    def test_upperstring(self):
        assert(str(DSCP("AF33")) == "30")

    def test_hexstring(self):
        self.assertTrue(str(DSCP("0x20")) == "32")

    def test_decstring(self):
        self.assertTrue(str(DSCP("48")) == "48")

    def test_int_string(self):
        self.assertTrue(int(DSCP("af33")) == 30)

    def test_dscp_lookup1(self):
        self.assertTrue(DSCP().dscp_lookup("cs7") == 56)

    def test_dscp_lookup2(self):
        self.assertTrue(DSCP().dscp_lookup("foobar") == None)

    def test_dscp_range1(self):
        self.assertTrue(DSCP().dscp_range("1,af11") == [ 1, 10 ])

    def test_dscp_range2(self):
        self.assertTrue(DSCP().dscp_range("5-7") == [ 5, 6, 7 ])

    def test_dscp_range3(self):
        self.assertTrue(DSCP().dscp_range("1,af22-af23") == [ 1, 20, 21,  22 ])

    def test_raise_valueerror1(self):
        try:
            DSCP("foobar")
        except ValueError:
            pass
        except:
            self.assertTrue(False)

    def test_raise_valueerror2(self):
        try:
            DSCP("128")
        except ValueError:
            pass
        except:
            self.assertTrue(False)

if __name__ == "__main__":
    unittest.main()
