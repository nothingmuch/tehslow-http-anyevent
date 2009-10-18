package TehSlow::HTTP::AnyEvent;
use Moose;

use MooseX::Types::Moose qw(Int Str);
use MooseX::Types::URI qw(Uri);

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Time::HiRes qw(time);

BEGIN {
    local $@;
    if ( eval { require Data::UUID::LibUUID; 1 } ) {
        Data::UUID::LibUUID->import("new_uuid_string");
    } else {
        require Data::GUID;
        *new_uuid_string = sub { Data::GUID->new->as_string };
    }
}

my %count;

sub ident ($) {
    join ".", $_[0], ++$count{$_[0]}; # new_uuid_string(); # easier to read for now
}

use namespace::clean -except => 'meta';

with qw(TehSlow::Output MooseX::Getopt MooseX::Runnable);

has id => (
    isa => Str,
    is  => "ro",
    lazy_build => 1,
);

sub _build_id { ident "tester" }

has num => (
    isa => Int,
    is  => "ro",
    default => 10,
);

has concurrency => (
    isa => Int,
    is  => "ro",
    default => 2,
);

has uri => (
    isa => Str,
    is  => "ro",
    coerce => 1,
    required => 1,
);

sub run {
    my $self = shift;

    my $cv = AE::cv;
    
    $self->event( 'tehslow.start', created => $self->id );

    my $remain = $self->num;

    my $uri = $self->uri;
    my $uri_obj = URI->new($uri);

    for ( 1 .. $self->concurrency ) {
        my $worker = ident "worker";

        $cv->begin;

        $self->event( 'tehslow.worker.start', resource => $self->id, created => $worker );
       
        my $worker_loop;
        $worker_loop = sub {
            unless ( $remain ) {
                undef $worker_loop;
                $self->event("tehslow.worker.end", resource => $worker);
                $cv->end;
                return;
            }

            $remain--;

            my $conn = ident "connection";
            my $guard;
            $guard = tcp_connect $uri_obj->host, $uri_obj->port, sub {
                if ( my ( $sock, @args ) = @_ ) {
                    $self->event('tcp.connection.established', resource => $conn );

                    my $h = AnyEvent::Handle->new( fh => $sock );

                    my $req = ident "request";

                    $self->event('http.request.start', resource => $conn, created => $req, data => { method => "GET", uri => $uri } );

                    my $written;

                    $h->on_drain(sub {
                        if ( not $written ) {
                            $written++;
                            $h->push_write("GET / HTTP/1.0\015\012Host: 0.0.0.0\015\012\015\012");
                        } else {
                            $h->on_drain;
                            $self->event('http.request.headers.finished', resource => $req );

                            $self->event('http.response.read', resource => $req );

                            my $length = 0;
                            $h->on_read(sub {
                                $self->event('http.response.start', resource => $req );
                                $h->on_read;

                                $h->push_read( line => "\015\012\015\012" => sub {
                                    my ( $h, $headers ) = @_;
                                    $self->event('http.response.headers.finished', resource => $req, data => $headers );

                                    $h->on_read(sub {
                                        $self->event('http.response.body.start', resource => $req);
                                        $h->on_read(sub{
                                            $length += length($h->{rbuf});
                                            delete $h->{rbuf};
                                        });
                                });
                                });
                            });

                            $h->on_eof(sub {
                                my $h = shift;
                                $self->event('http.response.finished', resource => $req, length => $length);
                                $h->destroy;
                                $self->event('tcp.connection.closed', resource => $conn);
                                undef $guard;
                                $worker_loop->();
                            });
                        }
                    });
                } else {
                    $self->event('tcp.connection.error', resource => $conn, data => { code => 0+$!, message => "$!" });
                }
            }, sub {
                $self->event( 'tcp.connection.open', resource => $worker, created => $conn, data => { host => $uri_obj->host, port => $uri_obj->port } );
            };
        };

        $worker_loop->();
    }

    $cv->recv;

    $self->event( 'tehslow.end', resource => $self->id );
}

__PACKAGE__->meta->make_immutable;

# ex: set sw=4 et:

__PACKAGE__

__END__
