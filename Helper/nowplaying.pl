#!/usr/bin/perl
# Usage: /usr/bin/perl nowplaying.pl /path/to/libTopShelfNowPlaying.dylib
# Runs the helper's ts_stream inside this Apple-signed perl, which the system Now Playing service still answers.
use strict; use DynaLoader;
my $lib = shift or die "usage: nowplaying.pl LIB\n";
my $h = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $s = DynaLoader::dl_find_symbol($h, "ts_stream") or die "missing ts_stream\n";
DynaLoader::dl_install_xsub("main::stream", $s);
stream();
