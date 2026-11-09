#!/usr/bin/perl
# Rewrite the BSD `sed -i ''` idiom into the GNU form this machine needs.
#
# A PreToolUse hook. Reads the payload on stdin, and answers with an
# updatedInput envelope when a command spells in-place editing the BSD way:
#
#     sed -i '' 's/alpha/OMEGA/' notes.md
#
# `sed` here is gnu-sed, ahead of /usr/bin on PATH. GNU sed takes an in-place
# suffix only when it is glued to the flag, so the separate `''` is read as
# the *script* -- an empty program, which is valid and does nothing -- and the
# real script becomes a filename:
#
#     sed: can't read s/alpha/OMEGA/: No such file or directory   # exit 2
#
# The named file is still opened and rewritten, byte for byte identical. That
# is the reason this is worth a hook rather than a line of instruction. Every
# other BSD/GNU mismatch on this machine announces itself with an `illegal
# option` and gets corrected on the next turn; this one reports success in the
# only way anyone checks -- the file is there, the command "ran" -- and the
# edit is simply absent. It was 84 occurrences across 22 sessions of the
# transcripts this hook was written from.
#
# The rewrite is dropping the empty argument, which is unambiguous: `-i` with
# no suffix is what the BSD form was asking for. No permissionDecision is
# emitted, so the corrected command still goes through the normal permission
# flow rather than being waved through by the rewrite.
#
# Only `sed` in command position is touched. Heredoc bodies are left alone,
# because a script being *authored* here may be targeting a stock macOS box
# where `sed -i ''` is the correct spelling, and rewriting it on the way to
# disk would plant the opposite bug. Occurrences inside quotes are left alone
# for the same reason: an earlier revision of this hook skipped that check and
# corrupted `python3 -c '...' "sed -i '' ..."` -- a quoted argument that was
# data, not a command -- within minutes of being installed.
#
# Perl for the same reason as guard-exit-echo.pl: /usr/bin/perl with core
# JSON::PP starts in ~60ms where /usr/bin/python3 costs ~1.5s, and this runs
# on every Bash tool call. Run --self-test after editing.

use strict;
use warnings;
use JSON::PP ();

# The opening line of a heredoc, whose body is data rather than shell. The
# quoted forms (<<'EOF') and the indented form (<<-EOF) all name a terminator
# the same way; the quoting only decides whether the body is expanded, which
# does not matter here.
my $HEREDOC = qr/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/;

# `sed` or `gsed`, then flags that stay inside one command -- `;` `&` `|` and
# newline all end it -- then `-i` followed by a *separate* empty string. The
# glued spellings `-i''` and `-i.bak` are already correct for GNU and carry no
# whitespace before the quotes, so the required \s excludes them.
my $BSD_INPLACE = qr/(\bg?sed\b[^;&|\n]*?\s-i)\s+(?:''|"")(?=\s)/;

# Which byte offsets of a line sit inside a quoted string. Only the opening
# position of the `sed` token is tested against this, so marking the quote
# characters themselves as inside costs nothing. A backslash outside single
# quotes escapes whatever follows it, which is the one case where a quote
# character does not open or close anything.
sub quoted_offsets {
    my ($line) = @_;
    my ( @inside, $single, $double );

    for ( my $i = 0; $i < length $line; $i++ ) {
        my $char = substr $line, $i, 1;

        if ( $char eq '\\' && !$single ) {
            $inside[$i] = $inside[ $i + 1 ] = ( $single || $double ) ? 1 : 0;
            $i++;
            next;
        }
        if ( $char eq q{'} && !$double ) { $single = !$single; $inside[$i] = 1; next }
        if ( $char eq q{"} && !$single ) { $double = !$double; $inside[$i] = 1; next }

        $inside[$i] = ( $single || $double ) ? 1 : 0;
    }

    return \@inside;
}

# Replace every BSD-form occurrence that is real shell: outside a heredoc body
# and outside quotes. Returns the new command, or undef when nothing changed.
sub rewrite {
    my ($command) = @_;
    my ( @out, $changed, $terminator );

    for my $line ( split /\n/, $command, -1 ) {

        # Inside a heredoc body: copy through, and watch for the terminator.
        if ( defined $terminator ) {
            push @out, $line;
            undef $terminator if $line =~ /^\s*\Q$terminator\E\s*$/;
            next;
        }

        my $rewritten = $line;
        my $from      = 0;

        while (1) {
            pos($rewritten) = $from;
            last unless $rewritten =~ /$BSD_INPLACE/g;

            my ( $start, $end, $sed_at, $keep ) = ( $-[0], $+[0], $-[1], $1 );

            # `sed` inside a quoted string is an argument to something else.
            if ( quoted_offsets($rewritten)->[$sed_at] ) {
                $from = $start + 1;
                next;
            }

            substr( $rewritten, $start, $end - $start ) = $keep;
            $changed++;
            $from = $start + length $keep;
        }

        push @out, $rewritten;

        # A heredoc opened on this line puts the following lines out of reach.
        # Only the first terminator is tracked, which is all a single command
        # line realistically opens.
        $terminator = $2 if $line =~ $HEREDOC;
    }

    return $changed ? join( "\n", @out ) : undef;
}

sub run_hook {
    my $raw = do { local $/; <STDIN> };
    return unless defined $raw && length $raw;
    my $payload = JSON::PP->new->decode($raw);
    return unless ( $payload->{tool_name} // '' ) eq 'Bash';

    my $input = $payload->{tool_input};
    return unless ref $input eq 'HASH' && defined $input->{command};

    my $rewritten = rewrite( $input->{command} );
    return unless defined $rewritten;

    # Echo the whole input back with only the command replaced, so the
    # description, timeout and background flag survive the rewrite.
    my %updated = ( %$input, command => $rewritten );

    print JSON::PP->new->canonical->encode(
        {   hookSpecificOutput => {
                hookEventName => 'PreToolUse',
                updatedInput  => \%updated,
            }
        }
    ), "\n";
    return;
}

# Cases the rule is written against, read from __DATA__ so no shell quoting
# has to survive a Perl string literal. A literal \n in a case becomes a
# newline. [rewrite] cases are `before => after`; [keep] cases must not
# change at all.
sub load_cases {
    my ( @rewrite, @keep );
    my $bucket;
    while ( my $line = <DATA> ) {
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^#/;
        if    ( $line eq '[rewrite]' ) { $bucket = \@rewrite; next }
        elsif ( $line eq '[keep]' )    { $bucket = \@keep;    next }
        $line =~ s/\\n/\n/g;
        push @$bucket, $line;
    }
    return ( \@rewrite, \@keep );
}

sub self_test {
    my ( $rewrite, $keep ) = load_cases();
    my $failed = 0;

    for my $case (@$rewrite) {
        my ( $before, $after ) = split / => /, $case, 2;
        my $got = rewrite($before);
        if ( !defined $got ) {
            print "FAIL (no rewrite): $before\n";
            $failed++;
        }
        elsif ( $got ne $after ) {
            print "FAIL: $before\n  want: $after\n  got:  $got\n";
            $failed++;
        }
    }

    for my $case (@$keep) {
        my $got = rewrite($case);
        if ( defined $got ) {
            print "FAIL (rewrote a keep case): $case\n  got: $got\n";
            $failed++;
        }
    }

    my $total = @$rewrite + @$keep;
    print $failed ? "$failed of $total failed\n" : "all $total cases pass\n";
    return $failed ? 1 : 0;
}

exit self_test() if @ARGV && $ARGV[0] eq '--self-test';
run_hook();

__DATA__

[rewrite]
# The plain form, both quote spellings.
sed -i '' 's/alpha/OMEGA/' notes.md => sed -i 's/alpha/OMEGA/' notes.md
sed -i "" 's/alpha/OMEGA/' notes.md => sed -i 's/alpha/OMEGA/' notes.md

# Flags on either side of -i.
sed -E -i '' 's/a+/b/' f.txt => sed -E -i 's/a+/b/' f.txt
sed -i '' -e 's/a/b/' -e 's/c/d/' f.txt => sed -i -e 's/a/b/' -e 's/c/d/' f.txt

# gnu-sed under its prefixed name.
gsed -i '' 's/a/b/' f.txt => gsed -i 's/a/b/' f.txt

# Reached through another command.
find . -name '*.md' -exec sed -i '' 's/a/b/' {} + => find . -name '*.md' -exec sed -i 's/a/b/' {} +
git ls-files | xargs sed -i '' 's/a/b/' => git ls-files | xargs sed -i 's/a/b/'

# One offender per segment, each rewritten independently.
sed -i '' 's/a/b/' one.txt && sed -i '' 's/c/d/' two.txt => sed -i 's/a/b/' one.txt && sed -i 's/c/d/' two.txt

# Inside a loop body spanning lines.
for f in *.md; do\n  sed -i '' 's/a/b/' "$f"\ndone => for f in *.md; do\n  sed -i 's/a/b/' "$f"\ndone

# Code before a heredoc is still code.
sed -i '' 's/a/b/' f.txt\ncat <<'EOF' > note.md\nhello\nEOF => sed -i 's/a/b/' f.txt\ncat <<'EOF' > note.md\nhello\nEOF

[keep]
# Already the GNU form.
sed -i 's/alpha/OMEGA/' notes.md

# Glued suffixes are correct for GNU and must survive untouched.
sed -i'' 's/a/b/' f.txt
sed -i.bak 's/a/b/' f.txt

# No in-place editing at all.
sed -n '5,10p' f.txt
sed 's/a/b/' in.txt > out.txt

# The empty string belongs to a different command.
echo '' | sed 's/a/b/'

# A macOS-targeted script being authored: the body is data, not shell.
cat <<'EOF' > fix.sh\n#!/bin/sh\nsed -i '' 's/a/b/' "$1"\nEOF

# Same, with the indented heredoc form.
cat <<-EOF > fix.sh\n\tsed -i '' 's/a/b/' "$1"\n\tEOF

# -i belongs to a different program entirely.
grep -i '' f.txt
perl -i -pe 's/a/b/' f.txt

# Quoted as data rather than run as a command. The regression that prompted
# quoted_offsets: this exact shape was corrupted by an earlier revision.
python3 -c "import sys;print(sys.argv[1])" "sed -i '' 's/a/b/' f.txt"
echo "sed -i '' 's/a/b/' f.txt"
printf '%s\n' "run: sed -i '' 's/a/b/' notes.md"
grep -n "sed -i '' " README.md

[rewrite]
# A quoted occurrence must not shadow a real one later on the same line: the
# scan has to skip past the quoted match and keep looking.
echo "sed -i '' is wrong" && sed -i '' 's/a/b/' f.txt => echo "sed -i '' is wrong" && sed -i 's/a/b/' f.txt
