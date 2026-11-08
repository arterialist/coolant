#!/bin/sh
# Command Line Tools installs do not put the Testing macro plugin on the default path.
cd "$(dirname "$0")/.."
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if xcode-select -p | grep -q CommandLineTools && [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins"
fi
exec swift test
