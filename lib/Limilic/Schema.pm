package Limilic::Schema;

use strict;
use warnings;
use utf8;
use parent qw/DBIx::Sunny::Schema/;
use Net::OpenID::Consumer;
use YAML;
use String::Random;
use Text::Xatena;
use DateTime;
use DateTime::Format::Strptime;
use Mouse::Util::TypeConstraints;

subtype 'Uint'
    => as 'Int'
    => where { $_ >= 0 };
    
no Mouse::Util::TypeConstraints;

my $DTFMT = DateTime::Format::Strptime->new(
    time_zone => 'Asia/Tokyo',
    pattern   => '%Y-%m-%d %H:%M:%S',
);

sub inflate_user {
    my $row = shift;
    my $identity = YAML::Load($row->{identity});
    $row->{identity} = Net::OpenID::VerifiedIdentity->new(
        consumer => Net::OpenID::Consumer->new,
        claimed_identity => Net::OpenID::ClaimedIdentity->new(
            identity => $row->{openid},
            semantic_info => {
                map { $_ => $identity->{$_} } qw/foaf foafmaker rss atom signed_fields/
            }
            )
    );
}

__PACKAGE__->select_row(
    'retrieve_user',
    id => 'Uint',
    q{SELECT * FROM users WHERE id=?},
    \&inflate_user
);

__PACKAGE__->select_row(
    'retrieve_openid_user',
    openid => 'Str',
    q{SELECT * FROM users WHERE openid=?},
    \&inflate_user
);

__PACKAGE__->query(
    'create_user',
    openid => 'Str',
    identity => {
        isa => 'Net::OpenID::VerifiedIdentity',
        deflater => sub {
            my $identity = shift;
            my %identity = map { $_ => $identity->$_ } 
                qw/foaf foafmaker rss atom signed_fields/;
            YAML::Dump(\%identity);
        },
    },
    created_on => {
        isa => 'DateTime',
        default => sub { DateTime->now( time_zone=>'Asia/Tokyo' ) },
        deflater => sub { $DTFMT->format_datetime(shift) },
    },
    q{INSERT INTO users (openid, identity, created_on) VALUES(?,?,?)}
);

__PACKAGE__->query(
    'update_openid_user',
    identity => {
        isa => 'Net::OpenID::VerifiedIdentity',
        deflater => sub {
            my $identity = shift;
            my %identity = map { $_ => $identity->$_ } 
                qw/foaf foafmaker rss atom signed_fields/;
            YAML::Dump(\%identity);
        },
    },
    openid => 'Str',
    q{UPDATE users SET identity = ? WHERE openid = ?}
);


__PACKAGE__->select_all(
    'retrieve_user_networks',
    user_id => 'Uint',
    q{SELECT * FROM user_networks WHERE user_id=?},
);

sub inflate_article {
    my ($row, $self) = @_;
    $row->{created_on} = $DTFMT->parse_datetime($row->{created_on});
    $row->{created_on}->set_time_zone("Asia/Tokyo");

    my $thx = Text::Xatena->new;
    $row->{converted_body} = $thx->format($row->{body});

    $row->{user} = $self->retrieve_user( id => $row->{user_id} );
    
    $row->{can_modify} = sub {
        my $user = shift;
        return if ! $user;
        my $user_id = $row->{user_id};
        my $acl_modify_mode = $row->{acl_modify_mode};

        #only user
        return 1 if ( $user_id == $user->{id} );
        #listed user
        return 1 if ( $acl_modify_mode == 3
            && $self->select_row( 'SELECT * FROM article_acl_modify WHERE article_id =? AND openid =?',
                                  $row->{id}, $user->{openid} ) );
        #all user
        return 1 if ( $acl_modify_mode == 4 && $user->{openid} );

        return;
    };
    $row->{can_view} = sub {
        my $user = shift;
        return 1 if ( $row->{can_modify}->($user) );

        my $user_id = $row->{user_id};
        my $acl_view_mode = $row->{acl_view_mode};

        #all
        return 1 if ( $acl_view_mode == 1 );
        #private
        return 1 if ( $acl_view_mode == 2 && $user && $user->{id} == $user_id );

        #custom
        return 1 if ( $acl_view_mode == 3 
            && $user
            && $self->select_row( 'SELECT * FROM article_acl_view WHERE article_id =? AND openid =?',
                                  $row->{id}, $user->{openid} )
        );

        return;
    };
}

__PACKAGE__->select_row(
    'retrieve_article',
    id => 'Uint',
    q{SELECT * FROM articles WHERE id=?},
    \&inflate_article
);

__PACKAGE__->select_row(
    'retrieve_rid_article',
    rid => 'Str',
    q{SELECT * FROM articles WHERE rid=?},
    \&inflate_article
);


sub login_openid_user {
    my $self = shift;
    my $args = $self->args(
        'openid'  => 'Str',
        'identity' => 'Net::OpenID::VerifiedIdentity',
    );

    my $txn = $self->txn_scope;
    my $ret = $self->update_openid_user(
        openid => $args->{openid},
        identity => $args->{identity}
    );

    if ( $ret && $ret == 0 ) {
        $self->create_user(
            openid => $args->{openid},
            identity => $args->{identity}
        );
    }

    my $user = $self->retrieve_openid_user(
        openid => $args->{openid},
    );
    $txn->commit;
    $user;
}

sub add_user_networks {
    my $self = shift;
    my $args = $self->args(
        'user_id' => 'Uint',
        'openid'  => 'Str',
    );

    my $txn = $self->txn_scope;

    if ( $self->select_row(q{SELECT * FROM user_networks WHERE user_id = ? AND openid = ?},$args->{user_id},$args->{openid})  ) {
        $txn->commit;
        return;
    }

    $self->query(
        q{INSERT INTO user_networks (user_id, openid) VALUES(?,?)},
        $args->{user_id},
        $args->{openid}
    );

    $txn->commit;
}

sub create_article {
    my $self = shift;
    my $args = $self->args(
        rid => {
            isa => 'Str',
            default => sub { String::Random->new->randregex('[a-z0-9]{16}' ) }
        },
        user_id => 'Uint',
        title => 'Str',
        body => 'Str',
        acl_view_mode => 'Uint',
        acl_modify_mode => 'Uint',
        anonymous => 'Uint',
        created_on => {
            isa => 'DateTime',
            default => sub { $DTFMT->format_datetime(DateTime->now(time_zone=>'Asia/Tokyo')) },
        },
        acl_custom_view_openid => 'ArrayRef[Str]',
        acl_custom_modify_openid => 'ArrayRef[Str]',
    );

    my $txn = $self->txn_scope;
    $self->query(
        q{INSERT INTO articles 
 (rid, user_id, title, body, acl_view_mode, acl_modify_mode, anonymous, created_on)
 VALUES (?,?,?,?,?,?,?,?)},
        map { $args->{$_} } qw/rid user_id title body acl_view_mode acl_modify_mode anonymous created_on/
    );

    my $article_id = $self->last_insert_id;

    for my $openid ( @{$args->{acl_custom_view_openid}} ) {
        $self->query(q{INSERT INTO article_acl_view (article_id,openid, user_id) VALUES (?,?,?)},
                     $article_id, $openid, $args->{user_id});
    }
    for my $openid ( @{$args->{acl_custom_modify_openid}} ) {
        $self->query(q{INSERT INTO article_acl_modify (article_id,openid, user_id) VALUES (?,?,?)},
                     $article_id, $openid, $args->{user_id});
    }

    $txn->commit;

    $args->{rid};
}


1;

