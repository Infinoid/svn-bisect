package App::SVN::Bisect;
use strict;
use warnings;

use Carp;
use File::Spec;
use IO::All;
use YAML::Syck;

our $VERSION = 0.9;

=head1 NAME

App::SVN::Bisect - binary search through svn revisions

=head1 SYNOPSIS

    my $bisect = App::SVN::Bisect->new(
        Action => $action,
        Min => $min,
        Max => $max
    );
    $bisect->do_something_intelligent(@ARGV);


=head1 DESCRIPTION

This module implements the backend of the "svn-bisect" command line tool.  See
the POD documentation of that tool, for usage details.


=head1 API METHODS

=cut


my %actions = (
    'after'  => { read_config => 1, write_config => 1, handler => \&after  },
    'bad'    => { read_config => 1, write_config => 1, handler => \&after  },
    'before' => { read_config => 1, write_config => 1, handler => \&before },
    'good'   => { read_config => 1, write_config => 1, handler => \&before },
    'help'   => { read_config => 0, write_config => 0, handler => \&help   },
    'reset'  => { read_config => 1, write_config => 0, handler => \&reset  },
    'skip'   => { read_config => 1, write_config => 1, handler => \&skip   },
    'start'  => { read_config => 0, write_config => 1, handler => \&start  },
    'unskip' => { read_config => 1, write_config => 1, handler => \&unskip },
    'view'   => { read_config => 1, write_config => 0, handler => \&view   },
);

=head2 new

    $self = App::SVN::Bisect->new(Action => "bad", Min => 0, Max => undef);

Create an App::SVN::Bisect object.  The arguments are typically parsed from
the command line.

The Action argument must be listed in the %actions table.  The "read_config"
attribute of the action determines whether the metadata file (typically named
.svn/bisect.yaml) will be read.

=cut

sub new {
    my ($package, %args) = @_;
    my $metadata = File::Spec->catfile(".svn", "bisect.yaml");
    die("You must specify an action!  Try running \"$0 help\".\n")
        unless defined $args{Action};
    my $action = $args{Action};
    die("Unknown action $action!  Try running \"$0 help\".\n")
        unless exists $actions{$action};
    my $self = {
        args     => \%args,
        action   => $action,
        config   => {
            skip => {},
        },
        metadata => $metadata,
    };
    if($actions{$action}{read_config}) {
        die("A bisect is not in progress!  Try \"$0 help start\".\n")
            unless -f $metadata;
        $$self{config} = Load(io($metadata)->all);
    }
    return bless($self, $package);
}


=head2 do_something_intelligent

    $self->do_something_intelligent(@ARGV);

Executes the action specified by the user.  See the "Action methods" section,
below, for the details.

If the action's "write_config" bit is set in the %actions table, the metadata
file will be written after executing the action.  If the bit was not set, the
metadata file is removed.

=cut

sub do_something_intelligent {
    my $self = shift;
    my $handler = $actions{$$self{action}}{handler};
    my $rv = &$handler($self, @_);
    unlink($$self{metadata});
    io($$self{metadata}) < Dump($$self{config})
        if $actions{$$self{action}}{write_config};
    return $rv;
}


=head1 ACTION METHODS

=head2 start

Begins a bisect session.  Sets up the parameters, queries some stuff about the
subversion repository, and starts the user off with the first bisect.

=cut

sub start {
    my $self = shift;
    die("A bisect is already in progress.  Try \"$0 help reset\".\n")
        if -f $$self{metadata};
    $$self{config}{min}  = $$self{args}{Min} if defined $$self{args}{Min};
    $$self{config}{orig} = $self->find_cur();
    my $max = $self->find_max();
    if(defined($$self{args}{Max})) {
        $$self{config}{max} = $$self{args}{Max};
        die("Given 'max' value is greater than the working directory maximum $max!\n")
            if $$self{config}{max} > $max;
    }
    return $self->next_rev();
}


=head2 before

Sets the "min" parameter to the specified (or current) revision, and
then moves the user to the middle of the resulting range.

=cut

sub before {
    my $self = shift;
    my $rev = shift;
    $rev = $$self{config}{cur} unless defined $rev;
    $rev = substr($rev, 1) if substr($rev, 0, 1) eq 'r';
    if($self->ready) {
        die("\"$rev\" is not a revision or is out of range.\n")
            unless exists($$self{config}{extant}{$rev});
    }
    $$self{config}{min} = $rev;
    return $self->next_rev();
}


=head2 after

Sets the "max" parameter to the specified (or current) revision, and
then moves the user to the middle of the resulting range.

=cut

sub after {
    my $self = shift;
    my $rev = shift;
    $rev = $$self{config}{cur} unless defined $rev;
    $rev = $$self{config}{cur} = $self->find_cur() unless defined $rev;
    $rev = substr($rev, 1) if substr($rev, 0, 1) eq 'r';
    if($self->ready) {
        die("\"$rev\" is not a revision or is out of range.\n")
            unless exists($$self{config}{extant}{$rev});
    } else {
        my $max = $self->find_max();
        die("$rev is greater than the working directory maximum $max!\n")
            if $max < $rev;
    }
    $$self{config}{max} = $rev;
    return $self->next_rev();
}


=head2 reset

Cleans up after a bisect session; moves the working tree back to the original
revision it had when "start" was first called.

=cut

sub reset {
    my $self = shift;
    my $orig = $$self{config}{orig};
    return $self->update_to($orig);
}


=head2 skip

Tells svn-bisect to ignore the specified (or current) revision, and
then moves the user to another, strategically useful revision.

You may specify as many revisions at once as you like.

=cut

sub skip {
    my $self = shift;
    my @rev = @_;
    @rev = $$self{config}{cur} unless scalar @rev;
    foreach my $rev (@rev) {
        die("\"$rev\" is not a revision or is out of range.\n")
            unless exists($$self{config}{extant}{$rev});
        $$self{config}{skip}{$rev} = 1;
    }
    return $self->next_rev();
}


=head2 unskip

Tells svn-bisect to stop ignoring the specified revision, then moves
the user to another, strategically useful revision.

You may specify as many revisions at once as you like.

=cut

sub unskip {
    my $self = shift;
    my @rev = @_;
    die("Usage: unskip <revision>\n") unless scalar @rev;
    foreach my $rev (@rev) {
        die("\"$rev\" is not a revision or is out of range.\n")
            unless exists($$self{config}{extant}{$rev});
        delete($$self{config}{skip}{$rev});
    }
    return $self->next_rev();
}


=head2 help

Allows the user to get some descriptions and usage information.

This function calls exit() directly, to prevent do_something_intelligent()
from removing the metadata file.

=cut

sub help {
    my ($self, $subcommand) = @_;
    $subcommand = '_' unless defined $subcommand;
    my %help = (
        '_' => <<"END",
Usage: $0 <subcommand>
where subcommand is one of:
    after  (alias: "bad")
    before (alias: "good")
    help   (hey, that's me!)
    reset
    skip
    start
    unskip
    view

For more info on a subcommand, try: $0 help <subcommand>
END
        'after' => <<"END",
Usage: $0 after [rev]
Alias: $0 bad [rev]

Tells the bisect routine that the specified (or current) checkout is
*after* the wanted change - after the bug was introduced, after the
change in behavior, whatever.
END
        'before' => <<"END",
Usage: $0 before [rev]
Alias: $0 good [rev]

Tells the bisect routine that the specified (or current) checkout is
*before* the wanted change - before the bug was introduced, before the
change in behavior, whatever.
END
        'reset' => <<"END",
Usage: $0 reset

Tries to clean up after itself, resets your checkout back to the original
version, and removes its temporary datafile.
END
        'skip' => <<"END",
Usage: $0 skip [<rev> [<rev>...]]

This will tell $0 to ignore the specified (or current)
revision.  You might want to do this if, for example, the current rev
does not compile for reasons unrelated to the current session.  You
may specify more than one revision, and they will all be skipped at
once.
END
        'start' => <<"END",
Usage: $0 [--min <rev>] [--max <rev>] start

Starts a new bisect session.  You may specify the initial upper and lower
bounds, with the --min and --max options.  These will be updated during the
course of the bisection, with the "before" and "after" commands.

This command will prepare the checkout for a bisect session, and start off
with a rev in the middle of the list of suspect revisions.
END
        'unskip' => <<"END",
Usage: $0 unskip <rev> [<rev>...]

Undoes the effects of "skip <rev>", putting the specified revision
back into the normal rotation (if it is still within the range of revisions
currently under scrutiny).  The revision argument is required.  You may
specify more than one revision, and they will all be unskipped at once.
END
        'view' => <<"END",
Usage: $0 view

Outputs some descriptive information about where we're at, and about
the revisions remaining to be tested.  The output looks like:

    There are currently 7 revisions under scrutiny.
    The last known-unaffected rev is 28913.
    The first known- affected rev is 28928.
    Currently testing 28924.
    
    Revision chart:
    28913] 28914 28918 28921 28924 28925 28926 28927 [28928

END
    );
    die("No known help topic \"$subcommand\".  Try \"$0 help\" for a list of topics.\n")
        unless exists $help{$subcommand};
    $self->stdout($help{$subcommand});
    $self->exit(0);
}


=head2 view

Allows the user to get some information about the current state of things.

This function calls exit() directly, to prevent do_something_intelligent()
from removing the metadata file.

=cut

sub view {
    my $self = shift;
    my $min = $$self{config}{min};
    my $max = $$self{config}{max};
    my %skips;
    if($self->ready) {
        my @revs = $self->list_revs();
        my $cur = $$self{config}{cur};
        $self->stdout("There are currently "
                      . scalar(@revs)
                      . " revisions under scrutiny.\n");
        $self->stdout("The last known unaffected rev is: $min.\n");
        $self->stdout("The first known affected rev is:  $max.\n");
        $self->stdout("Currently testing $cur.\n\n");
        if(@revs < 30) {
            $self->stdout("Revision chart:\n");
            $self->stdout("$min] " . join(" ", @revs) . " [$max\n");
        }
    } else {
        $self->stdout("Not enough information has been given to start yet.\n");
        $self->stdout("Bisecting may begin when a starting and ending revision are specified.\n");
        $self->stdout("The last known unaffected rev is: $min.\n") if defined $min;
        $self->stdout("The first known affected rev is:  $max.\n") if defined $max;
    }
    $self->exit(0);
}


=head1 INTERNAL METHODS

=head2 run

    my $stdout = $self->run("svn info");

Runs a command, returns its output.

=cut

sub run {
    my ($self, $cmd) = @_;
    $self->verbose("Running: $cmd\n");
    my $output = qx($cmd);
    my $rv = $? >> 8;
    if($rv) {
        $self->stdout("Failure to execute \"$cmd\".\n");
        $self->stdout("Please fix that, and then re-run this command.\n");
        $self->exit($rv);
    }
    return $output;
}


=head2 ready

    $self->next_rev() if $self->ready();

Returns a true value if we have enough information to begin bisecting.
Specifically, this returns true if we have been given at least one "bad"
and one "good" revision.  These can be specified as arguments to the
"before" and "after" commands, or as --min and --max arguments to the
"start" command.

=cut

sub ready {
    my $self = shift;
    return 0 unless defined $$self{config}{min};
    return 0 unless defined $$self{config}{max};
    $$self{config}{extant} = $self->fetch_log_revs()
        unless defined $$self{config}{extant};
    return 1;
}


=head2 next_rev

    $self->next_rev();

Find a spot in the middle of the current "suspect revisions" list, and calls
"svn update" to move the checkout directory to that revision.

=cut

sub next_rev {
    my $self = shift;
    return 0 unless $self->ready();
    my @revs = $self->list_revs();
    unless(scalar @revs) {
        my $max = $$self{config}{max};
        $$self{config}{min} = $$self{config}{cur} = $max;
        my $previous_skips = 0;
        my @previous_revisions = sort { $b <=> $a } keys %{$$self{config}{extant}};
        @previous_revisions = grep { $_ < $max } @previous_revisions;
        foreach my $rev (@previous_revisions) {
            if(exists($$self{config}{skip}{$rev})) {
                $previous_skips++;
            } else {
                last;
            }
        }
        $self->stdout("This is the end of the road!\n");
        if($previous_skips) {
            $self->stdout("The change occurred in r$max, or one of the "
                         ."$previous_skips skipped revs preceding it.\n");
        } else {
            $self->stdout("The change occurred in r$max.\n");
        }
        return $self->update_to($max);
    }
    my $ent = 0;
    $ent = scalar @revs >> 1 if scalar @revs > 1;
    my $rev = $$self{config}{cur} = $revs[$ent];
    $self->stdout("There are ", scalar @revs, " revs left in the pool."
                 ."  Choosing r$rev.\n");
    return $self->update_to($rev);
}


=head2 list_revs

    my @revs = $self->list_revs();

Returns the set of valid revisions between the current "min" and "max" values,
exclusive.

This is smart about revisions that don't affect the current tree (because they
won't be returned by fetch_log_revs, below) and about skipped revisions (which
the user may specify with the "skip" command).

=cut

sub list_revs {
    my $self = shift;
    confess("called when not ready") unless $self->ready();
    my $min = $$self{config}{min} + 1;
    my $max = $$self{config}{max} - 1;
    my @rv;
    foreach my $rev ($min..$max) {
        next if exists $$self{config}{skip}{$rev};
        push(@rv, $rev) if exists $$self{config}{extant}{$rev};
    }
    return @rv;
}


=head2 stdout

    $self->stdout("Hello, world!\n");

Output a message to stdout.  This is basically just the "print" function, but
we use a method so the testsuite can override it through subclassing.

=cut

sub stdout {
    my $self = shift;
    print(@_);
}


=head2 verbose

    $self->verbose("Hello, world!\n");

Output a message to stdout, if the user specified the --verbose option.  This
is basically just a conditional wrapper around the "print" function.

=cut

sub verbose {
    my $self = shift;
    return unless $$self{args}{Verbose};
    print(@_);
}


=head2 exit

    $self->exit(0);

Exits.  This allows the test suite to override exiting; it does not
provide any other features above and beyond what the normal exit
system call provides.

=cut

sub exit {
    my ($self, $rv) = @_;
    exit($rv);
}


=head1 SUBVERSION ACCESSOR METHODS

=head2 update_to

    $self->update_to(25000);

Calls 'svn update' to move to the specified revision.

=cut

sub update_to {
    my ($self, $rev) = @_;
    my $cmd = "svn update -r$rev";
    $self->run($cmd);
}


=head2 fetch_log_revs

    my $hashref = $self->fetch_log_revs();

Calls "svn log" and parses the output.  Returns a hash reference whose keys
are valid revision numbers; so you can use exists() to find out whether a
number is in the list.  This hash reference is used by list_revs(), above.

=cut

sub fetch_log_revs {
    my $self = shift;
    my $min = $$self{config}{min};
    my $max = $$self{config}{max};
    my %rv;
    my $log = $self->run("svn log -q -r$min:$max");
    $log =~ s/\r//;
    foreach my $line (split(/\n+/, $log)) {
        if($line =~ /^r(\d+) /) {
            $rv{$1} = 1;
        }
    }
    return \%rv;
}


=head2 find_max

    my $rev = $self->find_max();

Plays some tricks with "svn log" to figure out the latest revision contained
within the repository.

=cut

sub find_max {
    my $self = shift;
    my $log = $self->run("svn log -q -rHEAD:PREV");
    $log =~ s/\r//;
    foreach my $line (split(/\n+/, $log)) {
        if($line =~ /^r(\d+) /) {
            return $1;
        }
    }
    die("Cannot find highest revision in repository.");
}


=head2 find_cur

    my $rev = $self->find_cur();

Parses the output of "svn info" to figure out what the current revision is.

=cut

sub find_cur {
    my $self = shift;
    my $info = $self->run("svn info");
    $info =~ s/\r//;
    # parse the "Last Changed Rev:" entry
    foreach my $line (split(/\n+/, $info)) {
        if($line =~ /^Last Changed Rev: (\d+)/) {
            return $1;
        }
    }
    die("Cannot find current revision of checkout.");
}


=head1 AUTHOR

    Mark Glines <mark-cpan@glines.org>


=head1 THANKS

* Thanks to the git-bisect author(s), for coming up with a user interface that
I actually like.

* Thanks to Will Coleda for inspiring me to actually write and release this.

* Thanks to the Parrot project for having so much random stuff going on as to
make a tool like this necessary.


=head1 SEE ALSO

App::SVNBinarySearch by Will Coleda: L<http://search.cpan.org/dist/App-SVNBinarySearch/>


=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2008-2009 Mark Glines.

It is distributed under the terms of the Artistic License 2.0.  For details,
see the "LICENSE" file packaged alongside this module.

=cut

1;
