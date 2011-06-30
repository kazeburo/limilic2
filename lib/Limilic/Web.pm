package Limilic::Web;

use Shirahata3;
use Limilic::Schema;
use Limilic::Validator;
use Cache::Memcached::Fast;
use Net::OpenID::Consumer;
use LWP::UserAgent;
use LWPx::ParanoidAgent;
use Scope::Container::DBI;
use DBIx::Sunny;
use Digest::SHA qw/sha1_base64/;
use XML::Feed;
use Encode;
use Log::Minimal;

sub data {
    my $self = shift;
    local $Scope::Container::DBI::DBI_CLASS = 'DBIx::Sunny'; 
    my $dbh = Scope::Container::DBI->connect('dbi:mysql:limilic;host=127.0.0.1','','',{
        Callbacks => {
            connected => sub {
                my $connect = shift;
                $connect->do(q{SET SESSION time_zone="Asia/Tokyo"});
                return;
            },
        },
    });
    Limilic::Schema->new( dbh => $dbh );
}

sub memcached {
    my $self = shift;
    if ( !$self->{_memcached} ) {
        $self->{_memcached} = Cache::Memcached::Fast->new({
            servers => [qw/127.0.0.1:11211/],
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
        $c->stash->{session} = {};
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

            $c->stash->{session} = $ret;

            if ( $ret->{id} ) {
                my $user = eval {
                    $self->data->retrieve_user( id => $ret->{id} );
                };
                if ( !$user ) {
                    $c->stash->{session} = {};
                    $self->memcached->delete($id);
                    return;
                }
                $c->stash->{user} = $user;
            }
            $id;
        })->();

        if ( !$c->stash->{session}->{postkey} ) {
            my $postkey = sha1_base64( time . [] . $$ . rand() );
            $c->stash->{session}->{postkey} = $postkey;
        }

        my $res = $app->($self,$c);

        if ( ! keys %{$c->stash->{session}} ) {
            $self->memcached->delete($sid) if $sid;
            $res->cookies->{'lmlc'} = {
                value => '0',
                path => '/',
                expires => time - 3600*24*7
            };            
        }
        else {
            $sid ||= sha1_base64( time . [] . $$ . rand() );
            $self->memcached->set($sid, $c->stash->{session});
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
        if ( !$c->req->param('postkey') || $c->stash->{session}->{postkey} ne 
                 $c->req->param('postkey') ) {
            $c->halt(403);
        }
        $app->($self,$c);
    };
};

filter 'user' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        if ( ! $c->stash->{user} ) {
            $c->halt(403);
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
        $c->halt(404, 'entry not found') unless $article;
        
        if ( !$article->{can_view}->($c->stash->{user}) ) {
            $c->halt(403);
        }
        $c->stash->{article} = $article;
        $c->stash->{article_comment} =  $self->data->retrieve_article_comment( article_id => $article->{id} );
        
        $app->($self,$c);
    };
};

filter 'modify_entry' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        if ( !$c->stash->{article}->{can_modify}->($c->stash->{user}) ) {
            $c->halt(403);
        }
        $app->($self,$c);
    };
};

get '/' => [qw/session/] => sub {
    my ( $self, $c )  = @_;
    my $offset = $c->req->param('offset') || 0;
    my $rows = $self->data->recent_articles( offset => $offset );
    my $next;
    $next = pop @$rows if @$rows > 10;
    $c->render('index.tx', { articles => $rows, next => $next } );
};

get '/feed' => sub {
    my ( $self, $c )  = @_;
    my $rows = $self->data->recent_articles( offset => 0 );
    if ( ! @{$rows} ) {
        $c->halt(503);
    }
    my $feed = XML::Feed->new('Atom');
    $feed->title('LIMILIC');
    $feed->link($c->req->uri_for('/'));

    $feed->{atom}->add_link({
        rel => 'self',
        href => $c->req->uri_for('/feed'),
    });

    $feed->{atom}->add_link({
        rel => 'hub',
        href => 'http://pubsubhubbub.appspot.com',
    });

    $feed->modified($rows->[0]->{updated_on});
    $feed->description('new entries of LIMILIC');
    $feed->author('LIMILIC');
    $feed->{atom}->id(
        "tag:" . URI->new($c->req->base)->host . ",2007:" . URI->new($c->req->uri_for('/'))->path
    );

    for my $article ( @$rows ) {
        my $entry = XML::Feed::Entry->new('Atom');
        $entry->title($article->{title});
        $entry->link($c->req->uri_for('/entry/'.$article->{rid}));
        $entry->id(
            "tag:" . URI->new($c->req->base)->host . ",2007:" . URI->new($c->req->uri_for('entry/'.$article->{rid}))->path
        );
        $entry->issued($article->{created_on});
        $entry->modified($article->{updated_on});
        $entry->author( $article->{anonymous} ? 'anonymous' : $article->{user}->{openid} );
        $entry->summary( $article->{body} );
        $entry->{entry}->content( $article->{converted_body} );
        $feed->add_entry($entry);
    }

    $c->res->content_type('application/atom+xml;charset=UTF-8');
    $c->res->body(decode_utf8($feed->as_xml));
    $c->res;
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
            $c->stash->{session}->{id} = $user->{id};
        } else {
            croakf($csr->err);
        }
    }

    my $n = $c->req->param('n') || '/';
    $c->res->redirect($n);
};

post '/logout' => [qw/session postkey/] => sub {
    my ( $self, $c )  = @_;
    $c->stash->{session} = {};
    $c->res->redirect('/');
};

get '/account' => [qw/session user/] => sub {
    my ( $self, $c )  = @_;
    my $offset = $c->req->param('offset') || 0;
    my $rows = $self->data->user_articles( user_id => $c->stash->{user}->{id}, offset => $offset );
    my $next;
    $next = pop @$rows if @$rows > 10;
    $c->render('account.tx', { articles => $rows, next => $next } );
};

post '/account/preview' => [qw/session postkey user/] => sub {
    my ( $self, $c )  = @_;
    $self->data->convert_body($c->req->param('body'));
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
        $c->halt(403, 'no openid');
    }

    my $csr = Net::OpenID::Consumer->new(
        ua => ($c->debug ? 'LWP::UserAgent' : 'LWPx::ParanoidAgent')->new,
        args => $c->req->parameters->as_hashref,
        cache => $self->memcached,
        consumer_secret => sub { $_[0] },
    );

    my $identity = $csr->claimed_identity($c->req->param('openid_url'));
    if( !$identity ) {
        $c->halt(403, "openid resolution fail:". $csr->errcode);
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
    $c->render('entry.tx',{
        article_comments => $self->data->retrieve_article_comment(
            article_id => $c->stash->{article}->{id}
        ),
    });
};

get '/entry/{rid:[a-z0-9]{16}}/edit' => [qw/session entry modify_entry/] => sub {
    my ( $self, $c )  = @_;

    for my $col ( qw/title body acl_view_mode acl_modify_mode anonymous/ ) {
        $c->req->parameters->add($col, $c->stash->{article}->{$col});
    }
    $c->req->parameters->add('acl_custom_view_openid',
                             map { $_->{openid} } 
                                 @{$self->data->article_acl_view( article_id => $c->stash->{article}->{id})}); 
    $c->req->parameters->add('acl_custom_modify_openid',
                             map { $_->{openid} } 
                                 @{$self->data->article_acl_modify( article_id => $c->stash->{article}->{id})}); 

    my $user_networks = $self->data->retrieve_user_networks( user_id => $c->stash->{user}->{id} );
    my $article_histories = $self->data->article_histories( article_id => $c->stash->{article}->{id} );
    $c->render('edit.tx',{
        user_networks => $user_networks,
        article_histories => $article_histories,
    });
};

post '/entry/{rid:[a-z0-9]{16}}/edit' => [qw/session postkey entry modify_entry/] => sub {
    my ( $self, $c )  = @_;
    my $validator_key = $c->stash->{article}->{user_id} == $c->stash->{user}->{id} ? 'edit' : 'edit_limited';
    my $form = $self->validator->validate($c->req,$validator_key);
    if ( $form->has_error ) {
        my $user_networks = $self->data->retrieve_user_networks( user_id => $c->stash->{user}->{id} );
        my $article_histories = $self->data->article_histories( article_id => $c->stash->{article}->{id} );
        return $c->render('edit.tx',{
            user_networks => $user_networks,
            article_histories => $article_histories,
            form => $form,
        });
    }

    if ( $validator_key eq 'edit_limited' ) {
        $self->data->update_article_body(
            id => $c->stash->{article}->{id}, 
            title => $c->req->param('title'),
            body => $c->req->param('body'),
            openid => $c->stash->{user}->{openid},
        );
    }
    else {
        $self->data->update_article(
            id => $c->stash->{article}->{id}, 
            title => $c->req->param('title'),
            body => $c->req->param('body'),
            acl_view_mode => $c->req->param('acl_view_mode'),
            acl_modify_mode => $c->req->param('acl_modify_mode'),
            anonymous => $c->req->param('anonymous'),
            acl_custom_view_openid => [$c->req->param('acl_custom_view_openid')],
            acl_custom_modify_openid => [$c->req->param('acl_custom_modify_openid')],
            openid => $c->stash->{user}->{openid},
            user_id => $c->stash->{user}->{id},
        );
    }

    $c->res->redirect($c->req->uri_for('/entry/'.$c->stash->{article}->{rid}));
};

post '/entry/{rid:[a-z0-9]{16}}/delete' => [qw/session postkey entry modify_entry/] => sub {
    my ( $self, $c )  = @_;
    $self->data->delete_article(id => $c->stash->{article}->{id});
    $c->res->redirect($c->req->uri_for('/account'));
};

post '/entry/{rid:[a-z0-9]{16}}/comment' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;
    my $form = $self->validator->validate($c->req,'entry/comment');
    if ( $form->has_error ) {
        return $c->render('entry.tx', {
            form => $form,
            article_comments => $self->data->retrieve_article_comment(
                article_id => $c->stash->{article}->{id}
            ),
        });
    }
    $self->data->add_comment(
        article_id => $c->stash->{article}->{id},
        openid => $c->stash->{user}->{openid},
        body => $c->req->param('body'),
    );
    $c->res->redirect($c->req->uri_for('/entry/'.$c->stash->{article}->{rid}));
};

post '/entry/{rid:[a-z0-9]{16}}/comment/{cid:[0-9]+}/delete' => [qw/session postkey entry/] => sub {
    my ( $self, $c )  = @_;

    my $comment = $self->data->retrieve_comment(
        id => $c->args->{cid},
        article_id => $c->stash->{article}->{id}
    );

    $c->halt(404) if ( !$comment );
    if ( !$comment->{can_delete}->($c->stash->{user}) ) {
        $c->halt(403);
    }

    $self->data->delete_comment(id => $comment->{id} );
    $c->res->redirect($c->req->uri_for('/entry/'.$c->stash->{article}->{rid}));
};

1;

