// Copyright (c) 2020-2021, AT&T Intellectual Property. All rights reserved.
// All rights reserved.
//
// SPDX-License-Identifier: MPL-2.0
package main

import (
	"fmt"
	"os"

	"github.com/danos/vci"
)

type InterfaceState struct {
	Interface struct {
		State string `rfc7951:"state"`
		Name  string `rfc7951:"name"`
	} `rfc7951:"vyatta-interfaces-v1:interface"`
}

func exitOnError(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usage() {
	const usageFmt = `usage %s`
	fmt.Fprintf(os.Stderr, usageFmt+"\n", os.Args[0])
	os.Exit(1)
}

func emitNotification(name, state string) error {
	client, err := vci.Dial()
	if err != nil {
		// Prepare for early calls via udev,
		// even before the VCI bus is up.
		os.Exit(0)
	}
	defer client.Close()

	data := InterfaceState{}
	data.Interface.State = state
	data.Interface.Name = name

	return client.Emit("vyatta-interfaces-v1", "interface-state", data)
}

func main() {
	if len(os.Args) != 1 {
		usage()
	}

	name := os.Getenv("INTERFACE")
	if name == "" {
		err := fmt.Errorf("Error: enviornment INTERFACE is not set.")
		exitOnError(err)
	}
	state := os.Getenv("ACTION")
	if state == "" {
		err := fmt.Errorf("Error: enviornment ACTION is not set.")
		exitOnError(err)
	}

	err := emitNotification(name, state)
	exitOnError(err)
}
