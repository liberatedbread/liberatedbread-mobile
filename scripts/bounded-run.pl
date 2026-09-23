#!/usr/bin/env perl
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run a command under a wall-clock bound, the way GNU timeout would if every
# Mac had one: `bounded-run.pl SECONDS COMMAND [ARGS...]`.
#
# The command's own exit status passes through untouched. When the bound
# fires the command is sent SIGTERM — so `xcodebuild test` can tear down the
# on-device test host and the CoreDevice tunnel it spawned, and finish writing
# its .xcresult bundle — and, if it is still running GRACE seconds later,
# SIGKILL. Either way this exits 142 (128 + SIGALRM), the code the previous
# shape (`perl -e 'alarm shift; exec @ARGV'`) produced, which the runner and
# its selftest key on. That shape let the alarm kill xcodebuild outright: the
# app kept running on the phone, the next run on the same UDID found the
# device busy, and a half-written bundle was left behind.
#
# Signals to the child's process GROUP, so what xcodebuild spawned goes with
# it rather than being orphaned to init.
use strict;
use warnings;
use POSIX qw(setsid WNOHANG);

# Seconds between TERM and KILL. Ten is what xcodebuild needs to tear down an
# on-device host; the selftest sets LB_BOUNDED_GRACE=2 so proving the
# escalation does not cost the mirror ten seconds of sleep.
my $GRACE = $ENV{LB_BOUNDED_GRACE} // 10;
$GRACE = 10 unless $GRACE =~ /^\d+$/;

my ($seconds, @command) = @ARGV;
die "usage: bounded-run.pl SECONDS COMMAND [ARGS...]\n"
    unless defined $seconds && $seconds =~ /^\d+$/ && @command;

my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    setsid();                     # its own group: one kill reaches all of it
    exec @command or die "exec $command[0]: $!\n";
}

my $fired = 0;
local $SIG{ALRM} = sub {
    $fired = 1;
    kill 'TERM', -$pid;
    my $waited = 0;
    while ($waited < $GRACE) {
        my $reaped = waitpid($pid, WNOHANG);
        last if $reaped == $pid || $reaped == -1;
        sleep 1;
        $waited++;
    }
    kill 'KILL', -$pid;
};
# Forward an interrupt to the child too, so ^C on the runner does not leave
# xcodebuild running.
local $SIG{INT}  = sub { kill 'INT',  -$pid };
local $SIG{TERM} = sub { kill 'TERM', -$pid };

alarm $seconds;
my $reaped;
do { $reaped = waitpid($pid, 0) } while ($reaped == -1 && $!{EINTR});
alarm 0;

exit 142 if $fired;
my $status = $?;
exit(($status >> 8) & 0xff) if ($status & 0x7f) == 0;
exit(128 + ($status & 0x7f));
