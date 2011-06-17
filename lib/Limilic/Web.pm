package Limilic::Web;

use Shirahata3;
use Limilic::Session;
use Limilic::Schema;
use Limilic::Validator;
use Cache::Memcached::Fast;
use Net::OpenID::Consumer;
use LWP::UserAgent;
use LWPx::ParanoidAgent;
use Scope::Container::DBI;
use DBIx::Sunny;
use Digest::SHA qw/sha1_base64/;
use Text::Xatena;

sub data {
    my $self = shift;
    local $Scope::Container::DBI::DBI_CLASS = 'DBIx::Sunny'; 
    my $dbh = Scope::Container::DBI->connect('dbi:mysql:limilic;host=127.0.0.1','','');
    Limilic::Schema->new( dbh => $dbh );
}

sub memcached {
    my $self = shift;
    if ( !$self->{_memcached} ) {
        $self->{_memcached} = Cache::Memcached::Fast->new({
            servers => [qw/127.0.0.1:11211/],
            ketama_points => 150,
            utf8 => 1,
        });
    }
    $self->{_memcached};
}

sub validator {
    my $self = shift;
    if ( ! $self->{_validator} ) {
        my $fname = $self->root_dir . '/validator.pl';
        my $rules = eval {
            do $fname or die "Cannot load validator rules file: $fname";
        };
        die $@ if $@;
        $self->{_validator} = Limilic::Validator->new($rules);
    }
    $self->{_validator}
}

filter 'session' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        my $session = Limilic::Session->new;
        $c->stash->{session} = $session;
        my $sid = (sub {
            my $id = $c->req->cookies->{'lmlc'};
            return unless $id;

            if ( $id !~ m!^[A-Za-z0-9+/]{27}$! ) {
                return;
            }

            my $ret =  $self->memcached->get($id);
            if ( !$ret ) {
                return;
            }

            $session->init($ret);

            if ( $session->get('id') ) {
                my $user = eval {
                    $self->data->retrieve_user( id => $session->get('id') );
                };
                if ( !$user ) {
                    $session->init({});
                    $self->memcached->delete($id);
                    return;
                }
                $c->stash->{user} = $user;
            }
            $id;
        })->();

        if ( !$session->get('postkey') ) {
            my $postkey = sha1_base64( time . [] . $$ . rand() );
            $session->set('postkey', $postkey );
        }

        my $res = $app->($self,$c);

        if ( $session->logout ) {
            $self->memcached->delete($sid) if $sid;
            $res->cookies->{'lmlc'} = {
                value => '0',
                path => '/',
                expires => time - 3600*24*7
            };            
        }
        elsif ( $session->modified ) {
            $sid ||= sha1_base64( time . [] . $$ . rand() );
            $self->memcached->set($sid, $session->params);
            $res->cookies->{'lmlc'} = {
                value => $sid,
                path => '/',
                expires => time + 3600*24*7
            };
        }
        $res;
   };
};

filter 'postkey' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        if ( !$c->req->param('postkey') || $c->stash->{session}->get('postkey') ne 
                 $c->req->param('postkey') ) {
            HTTP::Exception->throw(403);
        }
        $app->($self,$c);
    };
};

filter 'user' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        if ( ! $c->stash->{user} ) {
            HTTP::Exception->throw(403);
        }
        $app->($self,$c);
    };
};

filter 'entry' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        my $rid = $c->args->{rid};
        my $article = $self->data->retrieve_rid_article( rid => $rid );
        HTTP::Exception->throw(404) unless $article;
        
        if ( !$article->{can_view}->($c->stash->{user}) ) {
            HTTP::Exception->throw(403);
        }
        $c->stash->{article} = $article;
        $app->($self,$c);
    };
};

get '/' => [qw/session/] => sub {
    my ( $self, $c )  = @_;
    $c->render('index.tx');
};

get '/feed' => sub {
    my ( $self, $c )  = @_;
};

post '/login' => [qw/session postkey/] => sub {
    my ( $self, $c )  = @_;

    my $csr = Net::OpenID::Consumer->new(
        ua => ($c->debug ? 'LWP::UserAgent' : 'LWPx::ParanoidAgent')->new,
        args => $c->req->parameters->as_hashref,
        cache => $self->memcached,
        consumer_secret => sub { $_[0] },
    );

    if (my $uri = $c->req->param('openid_url')) {
        my $identity = $csr->claimed_identity($uri)
            or croakf($csr->err);
        my $check_url = $identity->check_url(
            return_to => $c->req->uri_for('/login', [
                openid_check => 1,
                n => $c->req->param('n'),
            ]),
            trust_root => $c->req->uri_for('/'),
            delayed_return => 1,
        );
        return $c->res->redirect($check_url);
    }

    my $n = $c->req->param('n') || '/';
    $c->res->redirect($n);
};

get '/login' => [qw/session/] => sub {
    my ( $self, $c )  = @_;

    my $csr = Net::OpenID::Consumer->new(
        ua => ($c->debug ? 'LWP::UserAgent' : 'LWPx::ParanoidAgent')->new,
        args => $c->req->parameters->as_hashref,
        cache => $self->memcached,
        consumer_secret => sub { $_[0] },
    );

    if ($c->req->param('openid_check')) {
        if (my $setup_url = $csr->user_setup_url) {
            return $c->res->redirect($setup_url);
        } elsif ($csr->user_cancel) {
            return;
        } elsif (my $identity = $csr->verified_identity) {            
            my %identity = map { $_ => $identity->$_ } 
                qw/foaf foafmaker rss atom signed_fields/;
            my $user = $self->data->login_openid_user(
                openid => $identity->{identity},
                identity => $identity,
            );
            $c->stash->{session}->set('id',$user->{id});
        } else {
            croakf($csr->err);
        }
    }

    my $n = $c->req->param('n') || '/';
    $c->res->redirect($n);
};

post '/logout' => [qw/session postkey/] => sub {
    my ( $self, $c )  = @_;
    $c->stash->{session}->logout(1);
    $c->res->redirect('/');
};

get '/account' => [qw/session user/] => sub {
    my ( $self, $c )  = @_;
};

post '/account/preview' => [qw/session postkey user/] => sub {
    my ( $self, $c )  = @_;
    my $thx = Text::Xatena->new;
    $thx->format($c->req->param('body') || ' ');
};

post '/account/network' => [qw/session postkey user/] => sub {
    my ( $self, $c )  = @_;
    my $user_networks = $self->data->retrieve_user_networks( user_id => $c->stash->{user}->{id} );
    my @network = map { $_->{openid} } @$user_networks;
    $c->json({
        network => \@network
    });
};

post '/account/add_network' => [qw/session postkey user/] => sub {
    my ( $self, $c )  = @_;
    if( !$c->req->param('openid_url') ) {
        HTTP::Exception->throw(403, status_message=>'no openi');
    }

    my $csr = Net::OpenID::Consumer->new(
        ua => ($c->debug ? 'LWP::UserAgent' : 'LWPx::ParanoidAgent')->new,
        args => $c->req->parameters->as_hashref,
        cache => $self->memcached,
        consumer_secret => sub { $_[0] },
    );

    my $identity = $csr->claimed_identity($c->req->param('openid_url'));
    if( !$identity ) {
        HTTP::Exception->throw(403, status_message => "openid resolution fail:". $csr->errcode);
    }

    $self->data->add_user_networks(
        user_id => $c->stash->{user}->{id},
        openid => $identity->claimed_url,
    );
    $c->json({
        openid_url => $identity->claimed_url
    });
};

get '/create' => [qw/session user/] => sub {
    my ( $self, $c )  = @_;
    $c->req->parameters->add(acl_view_mode => 1) unless $c->req->param('acl_view_mode');
    $c->req->parameters->add(acl_modify_mode => 2)  unless $c->req->param('acl_modify_mode');
    $c->req->parameters->add(anonymous => 0) unless $c->req->param('anonymous');
    my $user_networks = $self->data->retrieve_user_networks( user_id => $c->stash->{user}->{id} );
    $c->render('create.tx',{
        user_networks => $user_networks,
    });
};

post '/create' => [qw/session postkey user/] => sub {
    my ( $self, $c )  = @_;

    my $form = $self->validator->validate($c->req,'create');
    if ( $form->has_error ) {
        my $user_networks = $self->data->retrieve_user_networks( user_id => $c->stash->{user}->{id} );
        return $c->render('create.tx',{
            user_networks => $user_networks,
            form => $form,
        });
    }

    my $rid = $self->data->create_article(
        user_id => $c->stash->{user}->{id},
        title => $c->req->param('title'),
        body => $c->req->param('body'),
        acl_view_mode => $c->req->param('acl_view_mode'),
        acl_modify_mode => $c->req->param('acl_modify_mode'),
        anonymous => $c->req->param('anonymous'),
        acl_custom_view_openid => [$c->req->param('acl_custom_view_openid')],
        acl_custom_modify_openid => [$c->req->param('acl_custom_modify_openid')],
    );

    $c->res->redirect($c->req->uri_for('/entry/'.$rid));
};

get '/entry/{rid:[a-z0-9]{16}}' => [qw/session entry/] => sub {
    my ( $self, $c )  = @_;
    $c->render('entry.tx');
};

get '/entry/{rid:[a-z0-9]{16}}/edit' => [qw/session entry/] => sub {
    my ( $self, $c )  = @_;
};

post '/entry/{rid:[a-z0-9]{16}}/edit' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;
};

post '/entry/{rid:[a-z0-9]{16}}/delete' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;
};

post '/entry/{rid:[a-z0-9]{16}}/add_comment' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;
};

post '/entry/{rid:[a-z0-9]{16}}/delete_comment' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;
};

1;

