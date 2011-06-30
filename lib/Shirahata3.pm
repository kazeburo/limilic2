package Shirahata3;

use strict;
use warnings;
use utf8;
use Carp qw//;
use Scalar::Util qw//;
use Plack::Builder;
use Plack::Builder::Conditionals;
use Router::Simple;
use Cwd qw//;
use File::Basename qw//;
use Log::Minimal 0.08;
use Text::Xslate 1.1003;
use HTML::FillInForm::Lite qw//;
use Try::Tiny;
use Class::Accessor::Lite (
    new => 0,
    rw => [qw/root_dir/]
);

our @EXPORT = qw/new root_dir psgi build_app _router _connect get post filter wrap_filter/;

sub import {
    my ($class, $name) = @_;
    my $caller = caller;
    for my $func (@EXPORT) {
        no strict 'refs';
        *{"$caller\::$func"} = \&$func;
    }
    strict->import;
    warnings->import;
    utf8->import;
}

sub new {
    my $class = shift;
    my $root_dir = shift;
    my @caller = caller;
    $root_dir ||= File::Basename::dirname( Cwd::realpath($caller[1]) );
    bless { root_dir => $root_dir }, $class;
}

sub psgi {
    my $self = shift;
    if ( ! ref $self ) {
        my $root_dir = shift;
        my @caller = caller;
        $root_dir ||= File::Basename::dirname( Cwd::realpath($caller[1]) );
        $self = $self->new($root_dir);
    }

    my $app = $self->build_app;
    $app = builder {
        enable match_if addr(qw/127.0.0.1/), 'ReverseProxy';
        enable match_if browser(qr!^Mozilla/4!), 'ForceEnv',
            "psgix.compress-only-text/html" => 1;
        enable match_if browser(qr!^Mozilla/4\.0[678]!), 'ForceEnv',
            "psgix.no-compress" => 1;
        enable match_if browser(qr!\bMSIE (?:7|8)!), 'ForceEnv',
            "psgix.no-compress" => 0,
            "psgix.compress-only-text/html" => 0;
        enable "Deflater",
            content_type => ['text/css','text/html','text/javascript','application/javascript','application/atom+xml'],
                vary_user_agent => 1;
        enable 'Static',
            path => sub { s!^/static/!! },
            root => $self->{root_dir} . '/static';
        enable 'Log::Minimal';
        enable 'Scope::Container';
        $app;
    };
}

sub build_app {
    my $self = shift;

    #router
    my $router = Router::Simple->new;
    $router->connect(@{$_}) for @{$self->_router};

    #xslate
    my $fif = HTML::FillInForm::Lite->new();
    my $tx = Text::Xslate->new(
        path => [ $self->root_dir . '/tmpl' ],
        input_layer => ':utf8',
        function => {
            fillinform => sub {
                my $q = shift;
                return sub {
                    my ($html) = @_;
                    return Text::Xslate::mark_raw( $fif->fill( \$html, $q ) );
                }
            }
        },
    );
    
    my $app = sub {
        my $env = shift;
        my $c = Shirahata3::Connection->new({
            tx => $tx,
            req => Shirahata3::Request->new($env),
            res => Shirahata3::Response->new(200),
            stash => {},
            debug => $ENV{PLACK_ENV} && $ENV{PLACK_ENV} eq 'development' ? 1 : 0,
        });
        $c->res->content_type('text/html; charset=UTF-8');

        my $p = try {
            local $env->{PATH_INFO} = Encode::decode_utf8( $env->{PATH_INFO}, 1 );
            $router->match($env)
        }
        catch {
            warnf $_;
            $c->halt(400,'unexpected character in request');
        };

        if ( $p ) {
            my $code = delete $p->{action};
            my $filters = delete $p->{filter};
            $c->args($p);

            my $app = sub {
                my ($self, $c) = @_;
                my $response;
                my $res = $code->($self, $c);
                croakf "Undefined Response" if !$res;
                my $res_t = ref($res) || '';
                if ( Scalar::Util::blessed $res && $res->isa('Plack::Response') ) {
                    $response = $res;
                }
                elsif ( $res_t eq 'ARRAY' ) {
                    $response = Shirahata3::Response->new(@$res);
                }
                elsif ( !$res_t ) {
                    $c->res->body($res);
                    $response = $c->res;
                }
                else {
                    croakf "Unknown Response: %s", $res_t;
                }
                $response;
            };

            for my $filter ( reverse @$filters ) {
                $app = $self->wrap_filter($filter,$app);
            }

            return $app->($self, $c)->finalize;
        }
        else {
            $c->halt(404);
        }
    };

    #copy from PM::HTTPExceptions
    sub {
        my $env = shift;
        my $res = try {
            $app->($env);
        } catch {
            if ( ref $_ && ref $_ eq 'Shirahata3::Exception' ) {
                return $_->response;
            }
            die $_;
        };

        return $res if ref $res eq 'ARRAY';
        return sub {
            my $respond = shift;
            my $writer;
            try {
                $res->(sub { return $writer = $respond->(@_) });
            } catch {
                if ($writer) {
                    Carp::cluck $_;
                    $writer->close;
                } else {
                    if ( ref $_ && ref $_ eq 'Shirahata3::Exception' ) {
                        return $respond->($_->response);
                    }
                    die $_;
                }
            };
        };
    };
}

my $_ROUTER={};
sub _router {
    my $klass = shift;
    my $class = ref $klass ? ref $klass : $klass; 
    if ( !$_ROUTER->{$class} ) {
        $_ROUTER->{$class} = [];
    }    
    if ( @_ ) {
        push @{ $_ROUTER->{$class} }, [@_];
    }
    $_ROUTER->{$class};
}

sub _connect {
    my $class = shift;
    my ( $methods, $pattern, $filter, $code ) = @_;
    if (!$code) {
        $code = $filter;
        $filter = [];
    }
    $class->_router(
        $pattern,
        { action => $code, filter => $filter },
        { method => [ map { uc $_ } @$methods ] } 
    );
}

sub get {
    my $class = caller;
    $class->_connect( ['GET','HEAD'], @_  );
}

sub post {
    my $class = caller;
    $class->_connect( ['POST'], @_  );
}

my $_FILTER={};
sub filter {
    my $class = caller;
    if ( !$_FILTER->{$class} ) {
        $_FILTER->{$class} = {};
    }    
    if ( @_ ) {
        $_FILTER->{$class}->{$_[0]} = $_[1];
    }
    $_FILTER->{$class};
}

sub wrap_filter {
    my $klass = shift;
    my $class = ref $klass ? ref $klass : $klass; 
    if ( !$_FILTER->{$class} ) {
        $_FILTER->{$class} = {};
    }
    my ($filter,$app) = @_;
    my $filter_subref = $_FILTER->{$class}->{$filter};
    croakf "Filter:%s is not exists", $filter unless $filter_subref;    
    return $filter_subref->($app);
}

1;

package Shirahata3::Exception;

use strict;
use warnings;

sub new {
    my $class = shift;
    my $code = shift;
    my %args = (
        code => $code,
    );
    if ( @_ == 1 ) {
        $args{message} = shift;
    }
    elsif ( @_ % 2 == 0) {
        %args = (
            %args,
            @_
        );
    }
    bless \%args, $class;
}

sub response {
    my $self = shift;
    my $code = $self->{code} || 500;
    my $message = $self->{message};
    $message ||= HTTP::Status::status_message($code);

    my @headers = (
         'Content-Type'   => 'text/plain',
         'Content-Length' => length($message),
    );

    if ($code =~ /^3/ && (my $loc = eval { $self->{location} })) {
        push(@headers, Location => $loc);
    }

    return [ $code, \@headers, [ $message ] ];
}

package Shirahata3::Connection;

use strict;
use warnings;
use JSON;
use Class::Accessor::Lite (
    new => 1,
    rw => [qw/req res stash args tx debug/]
);

*request = \&req;
*response = \&res;

sub halt {
    my $self = shift;
    die Shirahata3::Exception->new(@_);
}

sub render {
    my $self = shift;
    my $file = shift;
    my %args = ( @_ && ref $_[0] ) ? %{$_[0]} : @_;
    my %vars = (
        c => $self,
        stash => $self->stash,
        %args,
    );

    my $body = $self->tx->render($file, \%vars);
    $self->res->status( 200 );
    $self->res->content_type('text/html; charset=UTF-8');
    $self->res->body( $body );
    $self->res;
}

sub json {
    my $self = shift;
    my %args = ( @_ && ref $_[0] ) ? %{$_[0]} : @_;
    $self->res->status( 200 );
    $self->res->content_type('application/json; charset=UTF-8');
    $self->res->body( encode_json(\%args) );
    $self->res;
}

1;

package Shirahata3::Request;

use strict;
use warnings;
use parent qw/Plack::Request/;
use Hash::MultiValue;
use Encode;

sub body_parameters {
    my ($self) = @_;
    $self->{'shirahata2.body_parameters'} ||= $self->_decode_parameters($self->SUPER::body_parameters());
}

sub query_parameters {
    my ($self) = @_;
    $self->{'shirahata2.query_parameters'} ||= $self->_decode_parameters($self->SUPER::query_parameters());
}

sub _decode_parameters {
    my ($self, $stuff) = @_;

    my @flatten = $stuff->flatten();
    my @decoded;
    while ( my ($k, $v) = splice @flatten, 0, 2 ) {
        push @decoded, Encode::decode_utf8($k), Encode::decode_utf8($v);
    }
    return Hash::MultiValue->new(@decoded);
}
sub parameters {
    my $self = shift;

    $self->env->{'shirahata2.request.merged'} ||= do {
        my $query = $self->query_parameters;
        my $body  = $self->body_parameters;
        Hash::MultiValue->new( $query->flatten, $body->flatten );
    };
}

sub body_parameters_raw {
    shift->SUPER::body_parameters();
}
sub query_parameters_raw {
    shift->SUPER::query_parameters();
}

sub parameters_raw {
    my $self = shift;

    $self->env->{'plack.request.merged'} ||= do {
        my $query = $self->SUPER::query_parameters();
        my $body  = $self->SUPER::body_parameters();
        Hash::MultiValue->new( $query->flatten, $body->flatten );
    };
}

sub param_raw {
    my $self = shift;

    return keys %{ $self->parameters_raw } if @_ == 0;

    my $key = shift;
    return $self->parameters_raw->{$key} unless wantarray;
    return $self->parameters_raw->get_all($key);
}

sub uri_for {
     my($self, $path, $args) = @_;
     my $uri = $self->base;
     $uri->path($path);
     $uri->query_form(@$args) if $args;
     $uri;
}

1;

package Shirahata3::Response;

use strict;
use warnings;
use parent qw/Plack::Response/;
use Encode;

sub _body {
    my $self = shift;
    my $body = $self->body;
       $body = [] unless defined $body;
    if (!ref $body or Scalar::Util::blessed($body) && overload::Method($body, q("")) && !$body->can('getline')) {
        return [ Encode::encode_utf8($body) ];
    } else {
        return $body;
    }
}

sub redirect {
    my $self = shift;
    if ( @_ ) {
        $self->SUPER::redirect(@_);
        return $self;
    }
    $self->SUPER::redirect();
}

sub server_error {
    my $self = shift;
    my $error = shift;
    $self->status( 500 );
    $self->content_type('text/html; charset=UTF-8');
    $self->body( $error || 'Internal Server Error' );
    $self;
}

sub not_found {
    my $self = shift;
    my $error = shift;
    $self->status( 500 );
    $self->content_type('text/html; charset=UTF-8');
    $self->body( $error || 'Not Found' );
    $self;
}



1;



