#!/usr/bin/perl

#TODO: priorities

use strict;
use Gearman::Util;
use Carp ();
use IO::Socket::INET;
use String::CRC32 ();

package Gearman::Client;
use fields (
            'job_servers',
            'js_count',
            'sock_cache',  # hostport -> socket
            );

package Gearman::JobStatus;

sub new {
    my ($class, $known, $running, $nu, $de) = @_;
    undef $nu unless length($nu);
    undef $de unless length($de);
    my $self = [ $known, $running, $nu, $de ];
    bless $self;
    return $self;
}

sub known { my $self = shift; return $self->[0]; }
sub running { my $self = shift; return $self->[1]; }
sub progress { my $self = shift; return defined $self->[2] ? [ $self->[2], $self->[3] ] : undef; }
sub percent { my $self = shift; return (defined $self->[2] && $self->[3]) ? ($self->[2] / $self->[3]) : undef; }

package Gearman::Taskset;

use fields (
            'waiting',  # { handle => }
            'client',   # Gearman::Client
            'need_handle',  # arrayref

            'default_sock',     # default socket (non-merged requests)
            'default_sockaddr', # default socket's ip/port

            'loaned_sock',      # { hostport => socket }

            );


package Gearman::Task;

use fields (
            # from client:
            'func',
            'argref',
            # opts from client:
            'uniq',
            'on_complete',
            'on_fail',
            'on_status',
            'retry_count',
            'fail_after_idle',
            'high_priority',

            # from server:
            'handle',

            # maintained by this module:
            'retries_done',
            'taskset',
            'jssock',  # jobserver socket.  shared by other tasks in the same taskset,
                       # but not w/ tasks in other tasksets using the same Gearman::Client
            );

# ->new(Gearman::Taskset, $func, $argref, $opts);
sub new {
    my $class = shift;

    my $self = $class;
    $self = fields::new($class) unless ref $self;

    my $ts = shift;
    $self->{func} = shift;
    $self->{argref} = shift;

    my $opts = shift || {};
    for my $k (qw( uniq on_complete on_fail on_status retry_count fail_after_idle high_priority )) {
        $self->{$k} = delete $opts->{$k};
    }


    if (%{$opts}) {
        Carp::croak("Unknown option(s): " . join(", ", sort keys %$opts));
    }

    $self->{retries_done} = 0;
    $self->{taskset} = $ts;

    my $merge_on = $self->{uniq} eq "-" ? $self->{argref} : \ $self->{uniq};
    if ($$merge_on) {
        my $hash_num = _hashfunc($merge_on);
        $self->{jssock} = $ts->_get_hashed_sock($hash_num);
    } else {
        $self->{jssock} = $ts->_get_default_sock;
    }

    return $self;
}

# returns number in range [0,32767] given a scalarref
sub _hashfunc {
    return (String::CRC32::crc32(${ shift() }) >> 16) & 0x7fff;
}

sub submit_job_args_ref {
    my Gearman::Task $task = shift;
    return \ join("\0", $task->{func}, $task->{uniq}, ${ $task->{argref} });
}

sub fail {
    my Gearman::Task $task = shift;

    # try to retry, if we can
    if ($task->{retries_done} < $task->{retry_count}) {
        $task->{retries_done}++;
        $task->handle(undef);
        return $task->{taskset}->add_task($task);
    }

    return undef unless $task->{on_fail};
    $task->{on_fail}->();
    return undef;
}

sub complete {
    my Gearman::Task $task = shift;
    return unless $task->{on_complete};
    my $result_ref = shift;
    $task->{on_complete}->($result_ref);
}

sub status {
    my Gearman::Task $task = shift;
    return unless $task->{on_status};
    my ($nu, $de) = @_;
    $task->{on_status}->($nu, $de);
}

sub handle {
    my Gearman::Task $task = shift;
    return $task->{handle} unless @_;
    return $task->{handle} = shift;
}

package Gearman::Taskset;

sub new {
    my $class = shift;
    my Gearman::Client $client = shift;

    my $self = $class;
    $self = fields::new($class) unless ref $self;

    $self->{waiting} = {};
    $self->{need_handle} = [];
    $self->{client} = $client;
    $self->{loaned_sock} = {};

    return $self;
}

sub DESTROY {
    my Gearman::Taskset $ts = shift;

    if ($ts->{default_sock}) {
        $ts->{client}->_put_js_sock($ts->{default_sockaddr}, $ts->{default_sock});
    }

    while (my ($hp, $sock) = each %{ $ts->{loaned_sock} }) {
        $ts->{client}->_put_js_sock($hp, $sock);
    }
}

sub _get_loaned_sock {
    my Gearman::Taskset $ts = shift;
    my $hostport = shift;
    if (my $sock = $ts->{loaned_sock}{$hostport}) {
        return $sock if $sock->connected;
        delete $ts->{loaned_sock}{$hostport};
    }

    my $sock = $ts->{client}->_get_js_sock($hostport);
    return $ts->{loaned_sock}{$hostport} = $sock;
}

sub wait {
    my Gearman::Taskset $ts = shift;

    while (keys %{$ts->{waiting}}) {
        $ts->_wait_for_packet();
        # TODO: timeout jobs that have been running too long.  the _wait_for_packet
        # loop only waits 0.5 seconds.
    }
}

# ->add_task($func, <$scalar | $scalarref>, <$uniq | $opts_hashref>
#      opts:
#        -- uniq
#        -- on_complete
#        -- on_fail
#        -- on_status
#        -- retry_count
#        -- fail_after_idle
#        -- high_priority
# ->add_task(Gearman::Task)
#

sub add_task {
    my Gearman::Taskset $ts = shift;
    my $task;

    if (ref $_[0]) {
        $task = shift;
    } else {
        my $func = shift;
        my $arg_p = shift;   # scalar or scalarref
        my $opts = shift;    # $uniq or hashref of opts

        my $argref = ref $arg_p ? $arg_p : \$arg_p;
        unless (ref $opts eq "HASH") {
            $opts = { uniq => $opts };
        }

        $task = Gearman::Task->new($ts, $func, $argref, $opts);
    }

    my $req = Gearman::Util::pack_req_command("submit_job",
                                              ${ $task->submit_job_args_ref });
    my $len = length($req);
    my $rv = $task->{jssock}->syswrite($req, $len);
    die "Wrote $rv but expected to write $len" unless $rv == $len;

    push @{ $ts->{need_handle} }, $task;
    while (@{ $ts->{need_handle} }) {
        my $rv = $ts->_wait_for_packet($task->{jssock});
        if (! $rv) {
            shift @{ $ts->{need_handle} };  # ditch it, it failed.
            # this will resubmit it if it failed.
            print " INITIAL SUBMIT FAILED\n";
            return $task->fail;
        }
    }

    return $task->handle;
}

sub _get_default_sock {
    my Gearman::Taskset $ts = shift;
    return $ts->{default_sock} if $ts->{default_sock};

    my $getter = sub {
        my $hostport = shift;
        return
            $ts->{loaned_sock}{$hostport} ||
            $ts->{client}->_get_js_sock($hostport);
    };

    my ($jst, $jss) = $ts->{client}->_get_random_js_sock($getter);
    $ts->{loaned_sock}{$jst} ||= $jss;

    $ts->{default_sock} = $jss;
    $ts->{default_sockaddr} = $jst;
    return $jss;
}

sub _get_hashed_sock {
    my Gearman::Taskset $ts = shift;
    my $hv = shift;

    my Gearman::Client $cl = $ts->{client};

    for (my $off = 0; $off < $cl->{js_count}; $off++) {
        my $idx = ($hv + $off) % ($cl->{js_count});
        my $sock = $ts->_get_loaned_sock($cl->{job_servers}[$idx]);
        return $sock if $sock;
    }

    return undef;
}

# returns boolean when given a sock to wait on.
# otherwise, return value is undefined.
sub _wait_for_packet {
    my Gearman::Taskset $ts = shift;
    my $sock = shift;  # optional socket to singularly read from

    my ($res, $err);
    if ($sock) {
        $res = Gearman::Util::read_res_packet($sock, \$err);
        return 0 unless $res;
        return $ts->_process_packet($res);
    } else {
        # TODO: cache this vector?
        my ($rin, $rout, $eout);
        my %watching;

        for my $sock ($ts->{default_sock}, values %{ $ts->{loaned_sock} }) {
            next unless $sock;
            my $fd = $sock->fileno;

            vec($rin, $fd, 1) = 1;
            $watching{$fd} = $sock;
        }

        my $nfound = select($rout=$rin, undef, $eout=$rin, 0.5);
        return 0 if ! $nfound;

        foreach my $fd (keys %watching) {
            next unless vec($rout, $fd, 1);
            # TODO: deal with error vector
            my $sock = $watching{$fd};
            $res = Gearman::Util::read_res_packet($sock, \$err);
            $ts->_process_packet($res) if $res;
        }
        return 1;

    }
}

sub _process_packet {
    my Gearman::Taskset $ts = shift;
    my $res = shift;

    if ($res->{type} eq "job_created") {
        my Gearman::Task $task = shift @{ $ts->{need_handle} } or
            die "Um, got an unexpeted job_created notification";

        my $handle = ${ $res->{'blobref'} };
        $task->handle($handle);
        $ts->{waiting}{$handle} = $task;
        return 1;
    }

    if ($res->{type} eq "work_fail") {
        my $handle = ${ $res->{'blobref'} };
        my Gearman::Task $task = $ts->{waiting}{$handle} or
            die "Uhhhh:  got work_fail for unknown handle: $handle\n";

        delete $ts->{waiting}{$handle};
        $task->fail;
        return 1;
    }

    if ($res->{type} eq "work_complete") {
        ${ $res->{'blobref'} } =~ s/^(.+?)\0//
            or die "Bogus work_complete from server";
        my $handle = $1;
        my Gearman::Task $task = $ts->{waiting}{$handle} or
            die "Uhhhh:  got work_complete for unknown handle: $handle\n";

        $task->complete($res->{'blobref'});
        delete $ts->{waiting}{$handle};
        return 1;
    }

    if ($res->{type} eq "work_status") {
        my ($handle, $nu, $de) = split(/\0/, ${ $res->{'blobref'} });
        my Gearman::Task $task = $ts->{waiting}{$handle} or
            die "Uhhhh:  got work_status for unknown handle: $handle\n";

        $task->status($nu, $de);
        return 1;
    }

    die "Unknown/unimplemented packet type: $res->{type}";

}

package Gearman::Client;
use Socket qw(IPPROTO_TCP TCP_NODELAY SOL_SOCKET);

sub new {
    my ($class, %opts) = @_;
    my $self = $class;
    $self = fields::new($class) unless ref $self;

    $self->{job_servers} = [];
    $self->{js_count} = 0;
    $self->{sock_cache} = {};

    $self->job_servers(@{ $opts{job_servers} })
        if $opts{job_servers};


    return $self;
}

sub new_task_set {
    my Gearman::Client $self = shift;
    return Gearman::Taskset->new($self);
}

# getter/setter
sub job_servers {
    my Gearman::Client $self = shift;
    return $self->{job_servers} unless @_;
    my $list = [ @_ ];
    $self->{js_count} = scalar @$list;
    foreach (@$list) {
        $_ .= ":7003" unless /:/;
    }
    return $self->{job_servers} = $list;
}

sub dispatch_background {
    my Gearman::Client $self = shift;
    my ($func, $arg_p, $uniq) = @_;
    my $argref = ref $arg_p ? $arg_p : \$arg_p;
    Carp::croak("Function argument must be scalar or scalarref")
        unless ref $argref eq "SCALAR";

    my ($jst, $jss) = $self->_get_random_js_sock;
    return 0 unless $jss;

    my $req = Gearman::Util::pack_req_command("submit_job_bg",
                                              "$func\0$uniq\0$$argref");
    my $len = length($req);
    my $rv = $jss->write($req, $len);
    print "dispatch_background:  len=$len, rv=$rv\n";

    my $err;
    my $res = Gearman::Util::read_res_packet($jss, \$err);
    return 0 unless $res && $res->{type} eq "job_created";
    return "$jst//${$res->{blobref}}";
}

# returns a socket from the cache.  it should be returned to the
# cache with _put_js_sock.  the hostport isn't verified. the caller
# should verify that $hostport is in the set of jobservers.
sub _get_js_sock {
    my Gearman::Client $self = shift;
    my $hostport = shift;

    if (my $sock = delete $self->{sock_cache}{$hostport}) {
        return $sock if $sock->connected;
    }

    # TODO: cache, and verify with ->connected
    my $sock = IO::Socket::INET->new(PeerAddr => $hostport,
                                     Timeout => 1)
        or return undef;

    Carp::cluck("connected");

    setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;
    $sock->autoflush(1);
    # TODO: tcp_nodelay?
    return $sock;
}

# way for a caller to give back a socket it previously requested.
# the $hostport isn't verified, so the caller should verify the
# $hostport is still in the set of jobservers.
sub _put_js_sock {
    my Gearman::Client $self = shift;
    my ($hostport, $sock) = @_;

    $self->{sock_cache}{$hostport} ||= $sock;
}

sub _get_random_js_sock {
    my Gearman::Client $self = shift;
    my $getter = shift;
    return undef unless $self->{js_count};

    $getter ||= sub { my $hostport = shift; return $self->_get_js_sock($hostport); };

    my $ridx = int(rand($self->{js_count}));
    for (my $try = 0; $try < $self->{js_count}; $try++) {
        my $aidx = ($ridx + $try) % $self->{js_count};
        my $hostport = $self->{job_servers}[$aidx];
        my $sock = $getter->($hostport) or next;
        return ($hostport, $sock);
    }
    return ();
}

sub get_status {
    my Gearman::Client $self = shift;
    my $handle = shift;
    my ($hostport, $shandle) = split(m!//!, $handle);
    print "  hostport=[$hostport], shandle=[$shandle]\n";
    return undef unless grep { $hostport eq $_ } @{ $self->{job_servers} };

    my $sock = $self->_get_js_sock($hostport)
        or return undef;

    my $req = Gearman::Util::pack_req_command("get_status",
                                              $shandle);
    my $len = length($req);
    my $rv = $sock->write($req, $len);
    print "get_status:  len=$len, rv=$rv\n";

    my $err;
    my $res = Gearman::Util::read_res_packet($sock, \$err);
    return undef unless $res && $res->{type} eq "status_res";
    my @args = split(/\0/, ${ $res->{blobref} });
    return undef unless $args[0];
    shift @args;
    $self->_put_js_sock($hostport, $sock);
    return Gearman::JobStatus->new(@args);
}

1;