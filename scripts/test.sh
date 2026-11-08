#!/bin/sh
# Command Line Tools installs do not put the Testing macro plugin on the default path.
cd "$(dirname "$0")/.."
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
