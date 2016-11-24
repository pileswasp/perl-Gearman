use strict;
use warnings;
use Test::More;
use Test::Differences qw(eq_or_diff);
use IO::Socket::SSL ();

my $mn = "Gearman::Objects";
use_ok($mn);

can_ok(
    $mn, qw/
        _property
        canonicalize_job_servers
        debug
        job_servers
        prefix
        set_job_servers
        sock_nodelay
        socket
        use_ssl
        /
);


subtest "job servers", sub {
  {
    my $host = "foo";
    my $c = new_ok(
        $mn,
        [job_servers => $host],
        "Gearman::Objects->new(job_servers => $host)"
    );

    is(1, $c->{js_count}, "js_count=1");
    ok(my @js = $c->job_servers(), "job_servers");
    is(scalar(@js), 1, "job_servers count");

    eq_or_diff(
        $js[0],
        @{ $c->canonicalize_job_servers($host) }[0],
        "job_servers=$host"
    );
    is($js[0]->{host}, $host, "host");
    is($js[0]->{port}, 4730, "default port");
  }


my @servers = (qw/
    foo:12345
    bar:54321
    /, {host => "abc", "port" => 123});

    my $c = new_ok(
        $mn,
        [job_servers => [@servers]],
    );

    is(scalar(@servers), $c->{js_count}, "js_count=" . scalar(@servers));
    ok(my @js = $c->job_servers, "job_servers");
    for (my $i = 0; $i <= $#servers; $i++) {
        isa_ok($js[$i], "HASH");

        eq_or_diff(@{ $c->canonicalize_job_servers($servers[$i]) }[0],
            $js[$i], "canonicalize_job_servers($servers[$i])");
    }
};

subtest "debug", sub {
    my $c = new_ok($mn, [debug => 1]);
    is($c->debug(),  1);
    is($c->debug(0), 0);
    $c = new_ok($mn);
    is($c->debug(),  undef);
    is($c->debug(1), 1);
};

subtest "prefix", sub {
    my $p = "foo";
    my $c = new_ok($mn, [prefix => $p]);
    is($c->prefix(),      $p);
    is($c->prefix(undef), undef);
    $c = new_ok($mn);
    is($c->prefix(),   undef);
    is($c->prefix($p), $p);
};

subtest "use ssl", sub {
    my $c = new_ok($mn, [use_ssl => 1]);
    is($c->use_ssl(),  1);
    is($c->use_ssl(0), 0);
    $c = new_ok($mn);
    is($c->use_ssl(),  undef);
    is($c->use_ssl(1), 1);
};

subtest "socket", sub {
    my $dh  = "google.com";
    my $dst = $ENV{GEARMAND_ADDR_SSL} || join(':', $dh, 443);
    my $to  = int(rand(5)) + 1;
    my $c   = new_ok(
        $mn,
        [
            job_servers   => $dst,
            use_ssl       => 1,
            ssl_socket_cb => sub { my ($hr) = @_; $hr->{Timeout} = $to; }
        ]
    );

SKIP: {
        my $sock = $c->socket($dst);
        $sock || skip "failed connect to $dst or ssl handshake: $!, $IO::Socket::SSL::SSL_ERROR",
            2;
        isa_ok($sock, "IO::Socket::SSL");
        is($sock->timeout, $to, "ssl socket callback");
    } ## end SKIP:

    $dst = $ENV{GEARMAND_ADDR} ? $ENV{GEARMAND_ADDR} : join(':', $dh, 80);
    $c = new_ok($mn, [job_servers => $dst]);

SKIP: {
        my $sock = $c->socket($dst);
        $sock || skip "failed connect: $!", 1;
        isa_ok($sock, "IO::Socket::IP");
    }
};

done_testing();
