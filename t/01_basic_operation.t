use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use Test::Exception;
use Test::Output;
use App::SVN::Bisect;
use File::Spec::Functions;

my $tests;
BEGIN { $tests = 0; };
plan tests => $tests;

my $tempdir = tempdir( CLEANUP => 1 );
chdir($tempdir);
mkdir(".svn");

package test;
use Test::More;
our @ISA = qw(test2);
sub run {
    my ($self, $cmd) = @_;
    $$self{cmds} = [] unless exists $$self{cmds};
    push(@{$$self{cmds}}, $cmd);
    return $$self{rvs}{$cmd} if exists $$self{rvs}{$cmd};
    return '';
}

sub stdout {
    my ($self, @lines) = @_;
    my $text = join("", @lines);
    @lines = split(/[\r\n]+/, $text);
    $$self{stdout} = [] unless exists $$self{stdout};
    push(@{$$self{stdout}}, @lines);
}

sub exit {
    my $self = shift;
    die("exit");
}

package test2;
use Test::More;
our @ISA = qw(App::SVN::Bisect);
sub run {
    my ($self, $cmd) = @_;
    $$self{cmds} = [] unless exists $$self{cmds};
    push(@{$$self{cmds}}, $cmd);
    return $$self{rvs}{$cmd} if exists $$self{rvs}{$cmd};
    return '';
}

sub exit {
    my $self = shift;
    die("exit");
}

package main;

# constructor
throws_ok(sub { test->new() }, qr/specify an action/, "no Action");
throws_ok(sub { test->new(Action => 'unknown') }, qr/Unknown action/, "bad Action");
throws_ok(sub { test->new(Action => 'good') }, qr/not in progress/, "bad environment");
BEGIN { $tests += 3; };


my $test_responses = {
    "svn info" => <<EOF,
Blah: foo
Last Changed Rev: 16
Bar: baz
EOF
    "svn log -q -rHEAD:PREV" => <<EOF,
------------------------------------------------------------------------
r31 | foo | 2008-05-01 04:34:41 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r24 | bar | 2008-05-01 04:01:17 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r18 | baz | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r16 | quux | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r15 | bing | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
EOF
    "svn log -q -r0:31" => <<EOF,
------------------------------------------------------------------------
r31 | foo | 2008-05-01 04:34:41 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r24 | bar | 2008-05-01 04:01:17 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r18 | baz | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r16 | quux | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r15 | bing | 2008-05-01 03:08:32 -0700 (Thu, 01 May 2008)
------------------------------------------------------------------------
r12 | bing | 2008-04-01 03:08:32 -0700 (Thu, 01 Apr 2008)
------------------------------------------------------------------------
r8 | bob | 2008-04-01 03:08:31 -0700 (Thu, 01 Apr 2008)
------------------------------------------------------------------------
r1 | bob | 2008-04-01 03:08:30 -0700 (Thu, 01 Apr 2008)
------------------------------------------------------------------------
EOF
};

# so, the initial revspace is: (1 8 12 15 16 18 24 31)

# test default args
my $bisect = test->new(Action => "start", Verbose => 0);
ok(defined($bisect), "new() returns an object");
is(ref($bisect), "test", "new() blesses object into specified class");
ok(!-f catfile(".svn", "bisect.yaml"), "metadata file not created yet");
BEGIN { $tests += 3; };

# test readiness
ok(!$bisect->ready, "not ready yet");
$$bisect{config}{min} = 0;
ok(!$bisect->ready, "still not ready");
$$bisect{config}{max} = 31;
ok($bisect->ready , "ready now");
BEGIN { $tests += 3; };

# test "start"
$bisect = test->new(Action => "start", Min => 0, Max => 35, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok(sub { $bisect->do_something_intelligent() }, qr/working directory maximum/, "Max exceeds log");
$bisect = test->new(Action => "start", Min => 0, Max => 18, Verbose => 0);
$$bisect{rvs} = $test_responses;
lives_ok(sub { $bisect->do_something_intelligent() }, "Max in range lives");
unlink(catfile(".svn", "bisect.yaml"));
$bisect = test->new(Action => "start", Min => 0, Max => 31, Verbose => 0);
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
ok(-f catfile(".svn", "bisect.yaml"), "metadata file created");
is($$bisect{config}{max}, 31, "biggest svn revision was autodetected");
is($$bisect{config}{min}, 0 , "minimum is 0 by default");
is($$bisect{config}{orig},16, "Last Changed Rev: is parsed correctly");
is($$bisect{config}{cur}, 15, "first step: test r15");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r15/, "Choosing r15");
$bisect = test->new(Action => "start", Min => 0, Verbose => 0);
throws_ok(sub { $bisect->do_something_intelligent() }, qr/already in progress/, "re-start");
BEGIN { $tests += 10; };

# test "skip" and "unskip"
$bisect = test->new(Action => "skip", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok(sub {$bisect->do_something_intelligent("3") }, qr/out of range/, "invalid input");
$bisect->do_something_intelligent("15");
is($$bisect{config}{cur}, 16, "next step: test r16");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r16/, "Choosing r16");
$bisect = test->new(Action => "unskip", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok(sub {$bisect->do_something_intelligent()    }, qr/Usage/,        "missing param");
throws_ok(sub {$bisect->do_something_intelligent("3") }, qr/out of range/, "invalid input");
$bisect->do_something_intelligent("15");
is($$bisect{config}{cur}, 15, "first step: test r15");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r15/, "Choosing r15");
$bisect = test->new(Action => "skip", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
is($$bisect{config}{cur}, 16, "next step: test r16");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r16/, "Choosing r16");
BEGIN { $tests += 12; };

# test "view"
$bisect = test->new(Action => "view", Min => 0, Max => 31, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok( sub { $bisect->do_something_intelligent() }, qr/exit/, "normal exit");
is(scalar @{$$bisect{stdout}}, 6, "6 lines written");
is(join("\n", @{$$bisect{stdout}}, ""), <<EOF, "view output");
There are currently 6 revisions under scrutiny.
The last known unaffected rev is: 0.
The first known affected rev is:  31.
Currently testing 16.
Revision chart:
0] 1 8 12 16 18 24 [31
EOF
BEGIN { $tests += 3; };

# test "after"
$bisect = test->new(Action => "after", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok(sub {$bisect->do_something_intelligent("3") }, qr/out of range/, "invalid input");
$bisect->do_something_intelligent("16");
is($$bisect{config}{cur}, 8, "next step: test r8");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r8/, "Choosing r8");
$bisect = test->new(Action => "after", Min => 0, Verbose => 0);
$$bisect{config}{cur} = 16;
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
is($$bisect{config}{cur}, 8, "next step: test r8");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r8/, "Choosing r8");
BEGIN { $tests += 7; };

# test "before"
$bisect = test->new(Action => "before", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
throws_ok(sub {$bisect->do_something_intelligent("3") }, qr/out of range/, "invalid input");
$bisect = test->new(Action => "before", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent("8");
is($$bisect{config}{cur}, 12, "next step: test r12");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r12/, "Choosing r12");
$bisect = test->new(Action => "before", Min => 0, Verbose => 0);
$$bisect{config}{cur} = 8;
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
is($$bisect{config}{cur}, 12, "next step: test r12");
is(scalar @{$$bisect{stdout}}, 1, "1 line written");
like($$bisect{stdout}[0], qr/Choosing r12/, "Choosing r12");
BEGIN { $tests += 7; };

# test endgame with skipped revs
$bisect = test->new(Action => "skip", Min => 0, Verbose => 0);
$$bisect{config}{cur} = 12;
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
is($$bisect{config}{cur}, 16, "next step: test r16");
is(scalar @{$$bisect{stdout}}, 2, "2 lines written");
like($$bisect{stdout}[0], qr/This is the end of the road/, "road end");
like($$bisect{stdout}[1], qr/ 2 skipped revs preceding/, "counted skips");
BEGIN { $tests += 4; };

# test "reset"
ok(-f catfile(".svn", "bisect.yaml"), "metadata file still exists");
$bisect = test->new(Action => "reset", Min => 0, Verbose => 0);
$$bisect{rvs} = $test_responses;
$bisect->do_something_intelligent();
ok(!defined $$bisect{stdout}, "no output");
ok(!-f catfile(".svn", "bisect.yaml"), "metadata file removed");
BEGIN { $tests += 3; };

# test "help"
$bisect = test->new(Action => "help");
$$bisect{rvs} = $test_responses;
throws_ok(sub {$bisect->do_something_intelligent() }, qr/exit/, "help runs");
is(scalar @{$$bisect{stdout}}, 11, "several lines written");
like($$bisect{stdout}[0], qr/Usage:/, "first line is a Usage:");
throws_ok(sub {$bisect->do_something_intelligent('_') }, qr/exit/, "help runs");
is(scalar @{$$bisect{stdout}}, 22, "several lines written");
like($$bisect{stdout}[11], qr/Usage:/, "first line is a Usage:");
throws_ok(sub {$bisect->do_something_intelligent('nonexistent') }, qr/No known help topic/, "help dies");
BEGIN { $tests += 7; };


# test ->run()
$? = 0;
$$bisect{stdout} = [];
my $version = eval { App::SVN::Bisect::run($bisect, "svn --version") };
SKIP: {
    skip "no svn command found!", 4 if $?;

    like($version, qr/Subversion/, "svn --version output matches /Subversion/");
    throws_ok(sub { App::SVN::Bisect::run($bisect, "svn --unknown-arg 2>/dev/null") },
        qr/exit/, "handles error");
    is(scalar @{$$bisect{stdout}}, 2, "two lines written");
    like($$bisect{stdout}[1], qr/Please fix that/, "informative message");
};
BEGIN { $tests += 4; };


# test ->find_max()
is($bisect->find_max(), 31, 'find_max');
$$bisect{rvs}{'svn log -q -rHEAD:PREV'} = '';
throws_ok(sub { $bisect->find_max() }, qr/Cannot find/, 'find_max barfs');
BEGIN { $tests += 2; };


# test ->find_cur()
is($bisect->find_cur(), 16, 'find_cur');
$$bisect{rvs}{'svn info'} = '';
throws_ok(sub { $bisect->find_cur() }, qr/Cannot find/, 'find_cur barfs');
BEGIN { $tests += 2; };


# test ->stdout()
$bisect = test2->new(Action => "help", Verbose => 1);
stdout_like(sub { eval { $bisect->do_something_intelligent() } }, qr/^Usage:/, "stdout");
BEGIN { $tests += 1; };


# test ->verbose()
stdout_like(sub { $bisect->verbose("foo bar") }, qr/^foo bar$/, "verbose");
BEGIN { $tests += 1; };


# test ->exit()
App::SVN::Bisect->exit(0);
exit(1);
