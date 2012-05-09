
package App::livehttperf;
# ABSTRACT: Real life web performance testing tool

use strict;
use warnings;

use HTTP::Request;
use LWP::UserAgent;
use Parallel::ForkManager;
use Getopt::Long;
use Time::HiRes qw( gettimeofday tv_interval );
use Text::TabularDisplay;
use Statistics::Descriptive;
use Number::Bytes::Human qw( format_bytes );
use Time::Elapsed qw( -compile elapsed );
use List::Util qw( sum );
use utf8;

my @recs;
my %stats;
my @concurrency;
my $total_delays = 0;
my $total_urls = 0;
my $test_started;
my $elapsed_time;
my %ua_opts;

# xlsx output
my ($xls, $xls_summary, $xls_urls, $bold);
my $xls_s_row = 0;
my $xls_u_row = 0;

my %OPTS = (
    input => undef,
    reuse_cookies => 0,
    concurrency => [ 1 ],
    concurrency_max => 0,
    response_match_type => [],
    concurrency_step => 5,
    use_delay => 1,
    max_delay => 0,
    hostname => undef,
    verbosity => 1,
    quiet => 0,
    repeat => 10,
    timeout => 10,
    output => undef,
    output_xls => undef,
);
# subs

sub LOG(@)  { print @_, "\n" }
sub TRACE() { $OPTS{verbosity} >= 4; }
sub DEBUG() { $OPTS{verbosity} >= 3; }
sub INFO()  { $OPTS{verbosity} >= 2; }
sub WARN()  { $OPTS{verbosity} >= 1; }
sub ERROR() { ! $OPTS{quiet}; }

sub trim { s/\r?\n$// for @_ };
sub hb($) { return $_[0] ? 'Yes' : 'No' }

sub print_version {
    my $year = (localtime)[5] + 1900;
    my $years = $year != 2012 ? "2012-$year" : '2012';
    binmode STDOUT, ":utf8";
    print <<EOV;
livehttperf, version $App::livehttperf::VERSION  (perl $^V)

This software is copyright (c) $years by Alex J. G. Burzyński <ajgb\@cpan.org>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

EOV
};

sub configure {
    my $rv = GetOptions(
        'input|i=s' => \$OPTS{input},
        'output|o=s' => \$OPTS{output},
        'reuse_cookies|rc' => \$OPTS{reuse_cookies},
        'verbose|v+' => \$OPTS{verbosity},
        'quiet|q' => \$OPTS{quiet},
        'no_delay|nd' => sub { $OPTS{use_delay} = 0 },
        'max_delay|md=i' => \$OPTS{max_delay},
        'hostname|h=s' => \$OPTS{hostname},
        'match|m=s@' => \$OPTS{response_match_type},
        'response_match_type|m=s@' => \$OPTS{response_match_type},
        'concurrency|c=i@' => \$OPTS{concurrency},
        'concurrency_max|cm=i' => \$OPTS{concurrency_max},
        'concurrency_step|cs=i' => \$OPTS{concurrency_step},
        'repeat|n=i' => \$OPTS{repeat},
        'timeout|t=i' => \$OPTS{timeout},
        'version' => sub { print_version(); exit 0 },
        'help' => sub { print_usage(); exit 0 },
    );

    unless ( @ARGV || $rv ) {
        print_usage();
        exit 1;
    }

    {
        no warnings 'closure';
        if ( @{ $OPTS{response_match_type} } ) {
            eval q|
                sub App::livehttperf::response_matched {
                    return 0 unless $_[0]->status_line eq $_[1]->status_line;
                    my $eh = $_[0]->headers;
                    my $gh = $_[1]->headers;
                    for ( qw(|. join(' ', @{ $OPTS{response_match_type} } ) .q| ) ) {
                        my $ev = $eh->header($_);
                        my $gv = $gh->header($_);
                        return 0 unless defined $ev && defined $gv
                                        && $ev eq $gv;
                    }
                    return 1;
                }
            |;
        } else { # status_line only
            eval q{
                sub App::livehttperf::response_matched {
                    return $_[0]->status_line eq $_[1]->status_line;
                }
            };
        }
    }

    $OPTS{verbosity} = 0 if $OPTS{quiet};
    $OPTS{input} = '-' unless $OPTS{input};

    %ua_opts = (
        max_redirect => 0,
        timeout => $OPTS{timeout},
        keep_alive => 0,
    );

    if ( $OPTS{concurrency_max} && $OPTS{concurrency_step} ) {
        push @concurrency, 1
            unless $OPTS{concurrency_step} == 1;

        for ( my $c = $OPTS{concurrency_step}; $c <= $OPTS{concurrency_max}; $c += $OPTS{concurrency_step} ) {
            push @concurrency, $c;
        }
        push @concurrency, $OPTS{concurrency_max}
            unless $concurrency[-1] == $OPTS{concurrency_max};
    } else {
        push @concurrency, sort { $a <=> $b } @{ $OPTS{concurrency} };
    }

    if ( my $xlsx_file = $OPTS{output} ) {

        require Excel::Writer::XLSX;

        $xls = Excel::Writer::XLSX->new( $xlsx_file );
        $xls->set_optimization();
        $xls->set_properties(
            title => 'Performance tests',
            comments => "Generated by App::livehttperf/$App::livehttperf::VERSION",
        );
        $bold = $xls->add_format();
        $bold->set_bold();

        $xls_summary = $xls->add_worksheet('Summary');
        $xls_urls = $xls->add_worksheet('URLs');
    }

    $test_started = [ gettimeofday ];
}

sub parse_livehttp_log {
    local $/ = "----------------------------------------------------------\r\n";

    open(my $ifh, "<$OPTS{input}") or die "Cannot open $OPTS{input}: $!\n";
    while(my $rrb = <$ifh>) { # Request-Response block
        trim($rrb);

        my ($url, $req, $res, $req_bytes, $res_bytes);
        my @fh = split(/^/, $rrb);
        RRB: for(my $i = 0; $i < @fh; $i++) {
            my $l = $fh[$i]; # single line
            unless ( defined $url ) {
                trim($l);
                $url = $l;
                $i++;
                next;
            }

            # request
            if ( ! defined $req && $l =~ /^[A-Z]+ /) {
                my $req_hdrs = $l;
                my $cl;
                REQ: while( defined( $l = $fh[++$i] ) ) {
                    if ( ! $OPTS{reuse_cookies} && $l =~ /^Cookie/i ) {
                        next REQ;
                    }
                    if ( $l =~ /^HTTP\// ) { # reached response block
                        $i--;
                        last REQ;
                    }
                    if ( $l =~ /^Content-Length:[ \t]+(\d+)/i ) {
                        $cl = int($1);
                    }
                    $req_hdrs .= $l;
                }
                $req_hdrs =~ s/\r?\n\z//;
                my $post_data;
                if ( $cl ) { # post data requires Content-Length
                    $post_data = substr($req_hdrs, -1 * $cl);
                    $req_hdrs = substr($req_hdrs, 0, -1 * $cl);
                }
                $req = HTTP::Request->parse($req_hdrs);
                if ( defined $post_data ) {
                    unless ( length($post_data) == $req->header('Content-Length')) {
                        die "Content-Length header doesn't match the length of post data:\n$rrb\n$post_data\n",
                    };
                    $req->content( $post_data );
                }

                $req->uri( $url );
                if ( $OPTS{hostname} ) {
                    if ( $req->header('Host') ) {
                        $req->header( Host => $OPTS{hostname} );
                    }
                    my $new_host = $req->uri;
                    $new_host->host( $OPTS{hostname} );
                    $req->uri( $new_host );
                }
                next RRB;
            # response
            } elsif ( defined $req && $l =~ /^HTTP/ ) {
                $l =~ s/\r?\n\z//;
                # status line is parsed up to \n by HTTP::Response->parse()
                my $res_hdrs = "$l\n";
                RES: while( $l = $fh[++$i] ) {
                    last RES if $l =~ /^\-{58}/;
                    unless ( $OPTS{reuse_cookies} ) {
                        next if $l =~ /^Set-Cookie/i;
                    }
                    $res_hdrs .= $l;
                }
                $res = HTTP::Response->parse($res_hdrs);
                unless ( $ua_opts{keep_alive} ) {
                    if ( my $ka = $res->header('Keep-Alive') ) {
                        my ($max) = $ka =~ /max=(\d+)/;
                        $ua_opts{keep_alive} = $max || 100;
                    }
                }
                last RRB;
            }
        }

        if ( $req ) {
            if ( $OPTS{use_delay} ) {
                if ( @recs > 0 ) {
                    my $prev_date = $recs[-1]->{res}->headers->date;
                    my $cur_date = $res->headers->date;
                    my $delay = $cur_date - $prev_date;
                    if ( $delay > 0 ) {
                        my $delay_sec = $OPTS{max_delay} && $delay > $OPTS{max_delay} ?
                                $OPTS{max_delay} : $delay;
                        $total_delays += $delay_sec;

                        push @recs, $delay_sec;
                    }
                }
            }

            push @recs, {
                req => $req,
                res => $res,
                req_bytes => length $req->as_string,
                res_bytes => 0,
            };

            $total_urls++;

            last if @recs >= 3;
        };
    }
}

sub run_tests {

    $|=1;

    for my $concurrency ( @concurrency ) {
        LOG "\nRunning with concurrency of $concurrency" if INFO;
        my $pm = Parallel::ForkManager->new( $concurrency );

        $stats{$concurrency} = {
            reqs => Statistics::Descriptive::Full->new(),
            recs => {},
            counts => {
                successful_requests => 0,
                failed_requests => 0,
                bytes_sent => 0,
                bytes_recv => 0,
            },
            errors => {
                total => 0,
                recs => {}
            },
        };

        $pm->run_on_start(sub {
            my ($pid, $tid) = @_;

            $stats{$concurrency}->{started} = [ gettimeofday ];
        });
        $pm->run_on_finish(sub {
            my ($pid, $failures, $tid, $exit_signal, $core_dump, $data) = @_;

            $stats{$concurrency}->{elapsed} = tv_interval( $stats{$concurrency}->{started} );

            $stats{$concurrency}->{counts}->{failed_requests} += $failures;

            if ( defined $data ) {
                # all failed request by $rec_no
                $stats{$concurrency}->{errors}->{recs}->{$_} += $data->{errors}->{$_}
                    for keys %{ $data->{errors} };
                # add to stats total time of all requests in all runs
                $stats{$concurrency}->{reqs}->add_data(
                    @{ $data->{reqs} }
                );

                # sum counts
                $stats{$concurrency}->{counts}->{$_} += $data->{counts}->{$_}
                    for qw( successful_requests bytes_sent bytes_recv 1xx 2xx 3xx 4xx 5xx );

                # add to stats time of each request in all runs
                for my $rec_no ( keys %{ $data->{recs} } ) {
                    $stats{$concurrency}->{recs}->{$rec_no} = Statistics::Descriptive::Full->new()
                        unless exists $stats{$concurrency}->{recs}->{$rec_no};
                    $stats{$concurrency}->{recs}->{$rec_no}->add_data(
                        @{ $data->{recs}->{$rec_no} }
                    );
                }
            }
        });


        for my $tid ( 1 .. $concurrency ) {
            LOG "Starting thread $tid" if INFO;
            $pm->start($tid) and next;

            my $failed_requests = 0;
            my $successful_requests = 0;
            my %req_stats = (
                reqs => Statistics::Descriptive::Full->new(),
                recs => {},
                counts => {},
            );
            my @req_stats_data;
            my %rec_stats_data;
            my $bytes_sent = 0;
            my $bytes_recv = 0;
            my %rec_errors;
            my %res_statuses = (
                '1xx' => 0,
                '2xx' => 0,
                '3xx' => 0,
                '4xx' => 0,
                '5xx' => 0,
            );
            for my $no ( 1 .. $OPTS{repeat} ) {
                LOG "Starting run $no (thread $tid)" if INFO;

                # create brand new UA for each loop
                my $ua = LWP::UserAgent->new(
                    (
                        $OPTS{reuse_cookies} ?
                        ()
                        :
                        ( cookie_jar => {} )
                    ),
                    %ua_opts
                );

                my $rec_no = 0;
                for my $rec ( @recs ) {
                    $rec_no++;
                    if ( ! ref $rec ) {
                        LOG "[$tid.$no.$rec_no] Waiting for ", elapsed($rec) if DEBUG;
                        sleep $rec;
                        next;
                    }

                    my $req = $rec->{req};
                    $bytes_sent += $rec->{req_bytes};
                    my $exp_res = $rec->{res};
                    LOG "[$tid.$no.$rec_no] REQ:\n", $req->headers->as_string if DEBUG;
                    LOG "[$tid.$no.$rec_no] REQ:\n", $req->as_string if TRACE;
                    my $res;

                    # start of the request in run $no
                    my $rec_stats_start = [ gettimeofday ];
                    eval {
                        $res = $ua->request($req, $OPTS{verbosity} == 1 ? sub { print "." } : () )
                            or die "No response\n";
                    };
                    my $err = $@;
                    push @{ $rec_stats_data{$rec_no} }, tv_interval( $rec_stats_start );

                    if ( $res ) {
                        LOG "[$tid.$no.$rec_no] RES:\n", $res->headers->as_string if DEBUG;
                        LOG "[$tid.$no.$rec_no] RES:\n", $res->as_string if TRACE;

                        my $res_headers = $res->headers;
                        $bytes_recv += $res_headers->header('Content-Length') ||
                            (length($res_headers->as_string) + length($res->content));

                        $res_statuses{int($res->code / 100) .'xx'}++;
                    }
                    if ( $err || ! response_matched($exp_res, $res) ) {
                        $failed_requests++;
                        $rec_errors{$rec_no}++;
                        if ( ERROR ) {
                            my $nl = $OPTS{verbosity} == 1 ? "\n" : '';
                            if ( $res ) {
                                LOG "$nl\[$tid.$no.$rec_no] RES FAILED: ", $res->status_line;
                            } else {
                                LOG "$nl\[$tid.$no.$rec_no] RES FAILED: (no response)";
                            }
                        }
                        if ( TRACE ) {
                            LOG "  Exception: $err" if $err;
                        }
                    } else {
                        $successful_requests++;
                        LOG "[$tid.$no.$rec_no] RES: ", $res->status_line if DEBUG;
                    }
                }
                LOG "\nFinished run $no (thread $tid)" if INFO;
            }
            $req_stats{reqs} = [];
            for my $rec_no ( keys %rec_stats_data ) {
                for ( my $i = 0; $i < @{ $rec_stats_data{$rec_no} }; $i++ ) {
                    # total time of all requests in given run $no
                    $req_stats{reqs}->[$i] += $rec_stats_data{$rec_no}->[$i];
                }
            }
            $req_stats{recs} = { %rec_stats_data };
            $req_stats{errors} = { %rec_errors };
            $req_stats{counts} = {
                successful_requests => $successful_requests,
                bytes_sent => $bytes_sent,
                bytes_recv => $bytes_recv,
                %res_statuses,
            };


            LOG "\nFinished thread $tid" if INFO;
            $pm->finish($failed_requests, \%req_stats);
        }

        $pm->wait_all_children;

        LOG "\nFinished testing concurrency $concurrency" if INFO;
    }

    $elapsed_time = tv_interval( $test_started );
}

sub get_concurrency_time_stats {
    my ($concurrency) = @_;

    my $reqs = $stats{$concurrency}->{reqs};

    return (
        $concurrency,
        scalar localtime($stats{$concurrency}->{started}->[0]),
        sprintf("%.6f", $stats{$concurrency}->{elapsed}),
        ( map { sprintf("%.6f", $reqs->$_() ) } qw( min max mean standard_deviation median ) ),
    );
}


sub get_concurrency_res_stats {
    my ($concurrency) = @_;

    my $counts = $stats{$concurrency}->{counts};

    return (
        $concurrency,
        ( map { $counts->{$_} } qw( successful_requests failed_requests 1xx 2xx 3xx 4xx 5xx ) ),
    );
}


sub xlsx_row {
    return [ @_ ];
}

sub save_results {

    print "\n";

    {
        my $reqs_sent = $total_urls * $OPTS{repeat} * sum(@concurrency);
        my $test_run_at = localtime();

        print "\n";
        print "SUMMARY\n";
        print "  Test run at:            ", $test_run_at, "\n";
        print "  URLs tested:            ", $total_urls, "\n";
        print "  Total delays (per run): ", ($total_delays ? elapsed($total_delays) : '0'), "\n";
        print "  Requests sent:          ", $reqs_sent, "\n";
        print "  Test elapsed time:      ", ($elapsed_time < 1 ? '< 1 sec' : elapsed($elapsed_time)), "\n";
        print "\n";


        if ( $xls ) {
            my @columns = ('Test run at', 'URLs tested', 'Total delays (per run)', 'Requests sent', 'Test elapsed time');

            $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@columns), $bold);

            $xls_summary->write_row($xls_s_row++, 0, xlsx_row(
                $test_run_at,
                $total_urls,
                $total_delays,
                $reqs_sent,
                $elapsed_time
            ));
            $xls_s_row++;
        }
    }

    if ( INFO ) {
        my @columns = ('Option', 'Value');

        my $t = Text::TabularDisplay->new(@columns);

        $t->add('Input', $OPTS{input});
        $t->add('XLSX output', $OPTS{output} || '');
        $t->add('Reuse cookies', hb $OPTS{reuse_cookies});
        $t->add('Verbosity', $OPTS{verbosity});
        $t->add('Use delay', hb($OPTS{use_delay}) . ($OPTS{use_delay} && $OPTS{max_delay} ? " (max: $OPTS{max_delay} secs)" : ''));
        $t->add('Override hostname', hb($OPTS{hostname}) . ($OPTS{hostname} ? ": $OPTS{hostname}" : ''));
        $t->add('Concurrency', join(", ", @concurrency));
        $t->add('Repeats', $OPTS{repeat});
        $t->add('Connection timeout', $OPTS{timeout});
        $t->add('Compare headers', join("\n", @{ $OPTS{response_match_type} }));

        print "Configuration:\n";
        print $t->render, "\n";
        print "\n";
    }

    {
        my @columns = ('Concurrency', 'Started', 'Total', 'Min', 'Max', 'Avg', 'StdDev', 'Median');

        $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@columns), $bold)
            if $xls;

        my $t = Text::TabularDisplay->new(@columns);

        for my $c ( @concurrency ) {

            my @row = get_concurrency_time_stats($c);

            $t->add( @row );
            $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@row)) if $xls;
        }
        $xls_s_row++;

        print "Times (in seconds):\n";
        print $t->render, "\n";
        print "\n";
    }

    {
        my @columns = ('Concurrency', 'Successful', 'Failed', '1xx', '2xx', '3xx', '4xx', '5xx');

        $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@columns), $bold) if $xls;

        my $t = Text::TabularDisplay->new(@columns);

        for my $c ( @concurrency ) {

            my @row = get_concurrency_res_stats($c);

            $t->add( @row );

            $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@row)) if $xls;
        }
        $xls_s_row++;

        print "Responses:\n";
        print $t->render, "\n";
        print "\n";
    }

    {
        my @columns = ('Concurrency', 'Data sent', 'Data received');

        $xls_summary->write_row($xls_s_row++, 0, xlsx_row(@columns), $bold) if $xls;

        my $t = Text::TabularDisplay->new(@columns);

        for my $c ( @concurrency ) {

            my $counts = $stats{$c}->{counts};

            $t->add(
                $c,
                ( map { format_bytes( $counts->{$_} ) } qw( bytes_sent bytes_recv ) ),
            );

            $xls_summary->write_row($xls_s_row++, 0, xlsx_row(
                $c,
                ( map { $counts->{$_} } qw( bytes_sent bytes_recv ) ),
            )) if $xls;
        }
        $xls_s_row++;

        print "Data transfers:\n";
        print $t->render, "\n";
        print "\n";
    }

    {
        my @columns = ('Concurrency', 'URL', 'Min', 'Max', 'Avg', 'StdDev', 'Median', 'Errors');

        $xls_urls->write_row($xls_u_row++, 0, xlsx_row(@columns), $bold) if $xls;

        my $t = Text::TabularDisplay->new(@columns);

        for (my $rec_no = 1; $rec_no <= @recs; $rec_no++) {
            next unless ref $recs[$rec_no-1];
            for my $concurrency ( @concurrency ) {
                my $rec_stats = $stats{$concurrency}->{recs};
                my $rec_errors = $stats{$concurrency}->{errors}->{recs};

                my $url = $recs[$rec_no-1]->{req}->uri;
                my @row = (
                    $concurrency,
                    $url,
                    ( map { sprintf("%.6f", $rec_stats->{$rec_no}->$_() ) } qw( min max mean standard_deviation median ) ),
                    $rec_errors->{$rec_no} || 0
                );
                $t->add( @row );
                $xls_urls->write_row($xls_u_row++, 0, xlsx_row(@row)) if $xls;
            }
        }

        print "URLs:\n";
        print $t->render, "\n";
        print "\n";
    }

    $xls->close if $xls;
}

sub print_usage {
    print <<'EOH';
Usage: livehttperf [OPTIONS]

Input:
  -i, --input=file      Input file with recoreded session from LiveHTTP headers
                        Firefox extension.
                        Default: "-" (STDIN)

  -nd, --no_delay       Send requests one after another without detected delays.
                        Default: use delay

  -md, --max_delay=NUM  If using delay, wait for no more then NUM seconds
                        Default: none

  -h, --hostname=STRING Override hostname in requests and set Host header to
                        STRING.
                        Default: no change

  -rc, --reuse_cookies  Use Cookie/Set-Cookie headers from recorded session.
                        Default: do not reuse

Sessions:
  -n, --repeat=NUM      Repeat recorded session NUM times.
                        Default: 10

  -t, --timeout=NUM     Connection timeout.
                        Default: 10

  -m, --match=STRING    In addition to comparing HTTP response status line,
                        use specified STRING header to confirm successful
                        request. If provided multiple times all headers have
                        to match.
                        Default: none

  -c, --concurrency=NUM Run NUM concurrent connections. Can be provided
                        multiple times.
                        Default: 1

  -cs, --concurrency_step=NUM
  -cm, --concurrency_max=NUM
                        Alternatively specify maximum concurrency and
                        incremented by provided step value.
                        Default max: none
                        Default step: 5

Display and results:
  -o, --output=file     Save results in Excel 2007 (XLSX) format.
                        Default: none

  -v, --verbose         Repeat to increase verbosity level.
                        Available levels: WARN, INFO, DEBUG, TRACE.
                        Default: WARN

  -q, --quiet           Display only results.
                        Default: none


Examples:

  livehttperf -md 1 -cm 20 -o test.xlsx < session.txt
        Read session from session.txt, set maximum delay between requests to
        1 second and run with concurrency: 1, 5, 10, 15 and 20. Save results
        in test.xlsx

  livehttperf -nd -m Content-Length -t 5 -c 20 -c 50 < session.txt
        Read session from session.txt, require matching Content-Length header
        and run without any delay with concurrency: 20 and 50. Save results
        in test.xlsx

EOH
}

sub run {
    # configure
    configure();

    # parse input
    parse_livehttp_log();

    # run test
    run_tests();

    # display (and save) results
    save_results();
}


1;

=head1 SYNOPSIS

    livehttperf --help

=head1 DESCRIPTION

L<livehttperf> is a web performance testing tool using recorded sessions from
L<LiveHTTP headers Firefox extension|http://livehttpheaders.mozdev.org/>.

=head1 INSTALLATION

    cpanm App::livehttperf

=head1 HOW TO USE

This tool is intended to be used to compare how the changes of your web
application front/back-end impact user experience and the overall performance
of your web server.

=head2 Create repeatable test scenario

Therefore you need to create a I<typical> user session (browse a bit, add
products to basket, fill some forms, let some AJAX calls to be executed),
which you can then replay on the new version of your website.

I'd recommend L<Selenium IDE|http://seleniumhq.org/projects/ide/> to do so.

Remember to manually add I<pause> commands if you want to add delays between
navigating to other pages.

=head2 Record live requests/responses

Execute Selenium's test case with I<LiveHTTP headers> capturing live traffic.

Save to a file which will be used as input file for C<livehttperf>.

=head2 Prepare web / database server(s) for tests

Start some system monitoring tool on those servers to measure impact of
your test.

Install one (or both) packages:

=over 4

=item * sysstat

    man sar

=item * procps

    man vmstat

=back

=head2 Prepare your client server

Disable any processes that could impact the client server performance.

Use same tools as above to measure the impact of test.

=head2 Execute your tests

    livehttperf --help

Specify configuration options and run your tests.

Use LibreOffice Calc to open saved result file (XLSX format).

=head1 SEE ALSO

=over 4

=item * L<livehttperf>

=item * L<LiveHTTP headers Firefox extension|http://livehttpheaders.mozdev.org/>

=item * L<Selenium IDE|http://seleniumhq.org/projects/ide/>

=item * L<httperf|http://www.hpl.hp.com/research/linux/httperf/docs.php>

=back

=for Pod::Coverage
LOG
TRACE
DEBUG
INFO
WARN
ERROR
trim
hb
print_version
configure
parse_livehttp_log
run_tests
get_concurrency_time_stats
get_concurrency_res_stats
xlsx_row
save_results
print_usage
run

=cut


